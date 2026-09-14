#!/usr/bin/env python3
"""Session-scoped Anthropic Messages -> OpenAI Chat Completions adapter (stdlib)."""
import hmac
import hashlib
import ipaddress
import http.server
import json
import os
import re
import secrets
import signal
import subprocess
import sys
import tempfile
import threading
import urllib.error
import urllib.request
import urllib.parse
import uuid


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # Never forward the upstream credential to a redirected host.


def tool_name(name):
    """OpenAI limits function names to 64 ASCII identifier characters."""
    if re.fullmatch(r'[A-Za-z0-9_-]{1,64}', name):
        return name
    prefix = re.sub(r'[^A-Za-z0-9_-]', '_', name)[:39]
    return prefix + '_' + hashlib.sha256(name.encode()).hexdigest()[:24]


def text_content(value):
    if isinstance(value, str):
        return value
    return '\n'.join(b.get('text', '') for b in (value or []) if b.get('type') == 'text')


def content_parts(blocks):
    parts = []
    for block in blocks:
        kind = block.get('type')
        if kind == 'text':
            parts.append({'type': 'text', 'text': block['text']})
        elif kind == 'image':
            source = block['source']
            if source['type'] == 'base64':
                url = f"data:{source['media_type']};base64,{source['data']}"
            elif source['type'] == 'url':
                url = source['url']
            else:
                raise ValueError('Unsupported image source')
            parts.append({'type': 'image_url', 'image_url': {'url': url}})
        elif kind not in ('thinking', 'redacted_thinking', 'tool_use', 'tool_result'):
            raise ValueError(f'Unsupported content block: {kind}')
    if all(p['type'] == 'text' for p in parts):
        return '\n'.join(p['text'] for p in parts)
    return parts


def translate_request(body):
    messages = []
    if body.get('system'):
        messages.append({'role': 'system', 'content': text_content(body['system'])})
    for message in body['messages']:
        blocks = message['content']
        if isinstance(blocks, str):
            messages.append({'role': message['role'], 'content': blocks})
            continue
        # Tool replies must immediately follow the assistant's tool calls.
        for block in blocks:
            if block['type'] == 'tool_result':
                result = block.get('content', '')
                if isinstance(result, list):
                    result = content_parts(result)
                    if not isinstance(result, str):
                        raise ValueError('Image tool results are not supported by Chat Completions')
                messages.append({'role': 'tool', 'tool_call_id': block['tool_use_id'], 'content': result})
        content = content_parts(blocks)
        calls = [{'id': b['id'], 'type': 'function', 'function': {
            'name': tool_name(b['name']), 'arguments': json.dumps(b['input'])}}
            for b in blocks if b['type'] == 'tool_use']
        if content or calls:
            item = {'role': message['role'], 'content': content or None}
            if calls:
                item['tool_calls'] = calls
            messages.append(item)
    request = {'model': body['model'].removesuffix('[1m]'), 'messages': messages,
               'max_tokens': body.get('max_tokens', 4096), 'stream': True,
               'stream_options': {'include_usage': True}}
    for key in ('temperature', 'top_p'):
        if key in body:
            request[key] = body[key]
    if body.get('stop_sequences'):
        request['stop'] = body['stop_sequences']
    if body.get('tools'):
        request['tools'] = []
        for tool in body['tools']:
            if 'input_schema' not in tool:
                raise ValueError('Server-side Anthropic tools are not supported')
            request['tools'].append({'type': 'function', 'function': {
                'name': tool_name(tool['name']), 'description': tool.get('description', ''),
                'parameters': tool['input_schema']}})
        choice = body.get('tool_choice', {'type': 'auto'})
        kind = choice['type']
        request['tool_choice'] = ({'type': 'function', 'function': {'name': tool_name(choice['name'])}}
                                 if kind == 'tool' else {'any': 'required'}.get(kind, kind))
        if choice.get('disable_parallel_tool_use'):
            request['parallel_tool_calls'] = False
    fmt = body.get('output_config', {}).get('format')
    if fmt and fmt.get('type') == 'json_schema':
        request['response_format'] = {'type': 'json_schema', 'json_schema': {
            'name': 'response', 'schema': fmt['schema'], 'strict': True}}
    return request


def stream_chunks(response):
    # Standard SSE: events are separated by a blank line, with one or more data lines.
    data = []
    for raw in response:
        line = raw.decode('utf-8').rstrip('\r\n')
        if line.startswith('data:'):
            data.append(line[5:].lstrip())
        elif not line and data:
            payload = '\n'.join(data)
            data = []
            if payload == '[DONE]':
                return
            yield json.loads(payload)
    if data and '\n'.join(data) != '[DONE]':
        yield json.loads('\n'.join(data))


def usage_from_openai(usage):
    cached = (usage.get('prompt_tokens_details') or {}).get('cached_tokens', 0) or 0
    return {'input_tokens': max(0, usage.get('prompt_tokens', 0) - cached),
            'output_tokens': usage.get('completion_tokens', 0),
            'cache_read_input_tokens': cached, 'cache_creation_input_tokens': 0}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass  # Never log prompts, credentials, or request headers.

    def send_json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def event(self, kind, **values):
        self.wfile.write(('event: ' + kind + '\ndata: ' + json.dumps({'type': kind, **values}) + '\n\n').encode())
        self.wfile.flush()

    def do_POST(self):
        self.streaming = False
        auth = self.headers.get('x-api-key') or self.headers.get('Authorization', '').removeprefix('Bearer ')
        if not hmac.compare_digest(auth, self.server.local_token):
            self.send_json(401, {'type': 'error', 'error': {'type': 'authentication_error', 'message': 'Invalid local adapter credential'}})
            return
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 32 * 1024 * 1024:
                raise ValueError('Request body must be between 1 byte and 32 MiB')
            body = json.loads(self.rfile.read(length))
            path = self.path.split('?', 1)[0]
            if path == '/v1/messages/count_tokens':
                # Approximation only: providers do not expose a common tokenizer API.
                count = len(json.dumps({k: body[k] for k in ('system', 'messages', 'tools') if k in body}).encode())
                self.send_json(200, {'input_tokens': max(1, (count + 2) // 3)})
            elif path == '/v1/messages':
                self.messages(body)
            else:
                self.send_json(404, {'type': 'error', 'error': {'type': 'not_found_error', 'message': 'Unknown adapter endpoint'}})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as error:
            status = error.code if isinstance(error, urllib.error.HTTPError) else 400 if isinstance(error, (ValueError, KeyError)) else 502
            message = str(error)
            if isinstance(error, urllib.error.HTTPError):
                message = error.read(4096).decode(errors='replace')
            message = message.replace(self.server.api_key, '<redacted>')
            detail = {'type': 'api_error', 'message': message}
            if self.streaming:
                self.event('error', error=detail)
            else:
                self.send_json(status, {'type': 'error', 'error': detail})
        finally:
            if self.streaming:
                self.close_connection = True

    def messages(self, body):
        payload = translate_request(body)
        original_names = {tool_name(t['name']): t['name'] for t in body.get('tools', [])}
        request = urllib.request.Request(self.server.base_url.rstrip('/') + '/chat/completions',
            data=json.dumps(payload).encode(), headers={'Authorization': 'Bearer ' + self.server.api_key,
            'Content-Type': 'application/json', 'User-Agent': 'clauder-openai-adapter/1.0'})
        with urllib.request.build_opener(NoRedirect).open(request, timeout=180) as response:
            stream = body.get('stream', False)
            message_id = 'msg_' + uuid.uuid4().hex
            content = []
            usage = usage_from_openai({})
            calls = {}
            text = ''
            text_started = False
            reason = None
            if stream:
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Cache-Control', 'no-cache')
                self.send_header('Connection', 'close')
                self.end_headers()
                self.streaming = True
                self.event('message_start', message={'id': message_id, 'type': 'message', 'role': 'assistant',
                    'model': body['model'], 'content': [], 'stop_reason': None, 'stop_sequence': None, 'usage': usage})
            for chunk in stream_chunks(response):
                if chunk.get('error'):
                    raise ValueError(json.dumps(chunk['error']))
                if chunk.get('usage'):
                    usage = usage_from_openai(chunk['usage'])
                for choice in chunk.get('choices', []):
                    if choice.get('index', 0) != 0:
                        continue
                    delta = choice.get('delta', {})
                    value = delta.get('content') or ''
                    if value:
                        if stream and not text_started:
                            self.event('content_block_start', index=0, content_block={'type': 'text', 'text': ''})
                        text_started = True
                        text += value
                        if stream:
                            self.event('content_block_delta', index=0, delta={'type': 'text_delta', 'text': value})
                    for call in delta.get('tool_calls', []):
                        acc = calls.setdefault(call['index'], {'id': '', 'name': '', 'arguments': ''})
                        if call.get('id'):
                            acc['id'] = call['id']
                        function = call.get('function', {})
                        acc['name'] += function.get('name') or ''
                        acc['arguments'] += function.get('arguments') or ''
                    reason = choice.get('finish_reason') or reason
            if reason is None:
                raise ValueError('Upstream stream ended without a finish reason')
            if text_started:
                content.append({'type': 'text', 'text': text})
                if stream:
                    self.event('content_block_stop', index=0)
            for key in sorted(calls):
                call = calls[key]
                if not call['name'] or not call['id']:
                    raise ValueError('Incomplete upstream tool call')
                arguments = json.loads(call['arguments'] or '{}')
                if not isinstance(arguments, dict):
                    raise ValueError('Tool arguments must be a JSON object')
                block = {'type': 'tool_use', 'id': call['id'],
                         'name': original_names.get(call['name'], call['name']), 'input': arguments}
                index = len(content)
                content.append(block)
                if stream:
                    self.event('content_block_start', index=index, content_block={**block, 'input': {}})
                    self.event('content_block_delta', index=index, delta={'type': 'input_json_delta', 'partial_json': json.dumps(arguments)})
                    self.event('content_block_stop', index=index)
            stop = 'tool_use' if calls else {'length': 'max_tokens', 'content_filter': 'refusal'}.get(reason, 'end_turn')
            if stream:
                self.event('message_delta', delta={'stop_reason': stop, 'stop_sequence': None}, usage=usage)
                self.event('message_stop')
            else:
                self.send_json(200, {'id': message_id, 'type': 'message', 'role': 'assistant', 'model': body['model'],
                    'content': content, 'stop_reason': stop, 'stop_sequence': None, 'usage': usage})


def session_settings(arguments, local_env):
    """Merge caller settings so the adapter does not discard user overrides."""
    args = []
    settings = {}
    values = iter(arguments)
    for arg in values:
        if arg == '--settings' or arg.startswith('--settings='):
            value = next(values) if arg == '--settings' else arg.split('=', 1)[1]
            if value.lstrip().startswith('{'):
                incoming = json.loads(value)
            else:
                with open(value) as handle:
                    incoming = json.load(handle)
            if not isinstance(incoming, dict):
                raise ValueError('--settings must contain a JSON object')
            settings.update(incoming)
        else:
            args.append(arg)
    settings['env'] = {**settings.get('env', {}), **local_env}
    return args, settings


def valid_base_url(value):
    url = urllib.parse.urlsplit(value)
    if not url.hostname or url.username or url.password or url.query or url.fragment:
        return False
    if url.scheme == 'https':
        return True
    if url.scheme != 'http':
        return False
    if url.hostname == 'localhost':
        return True
    try:
        address = ipaddress.ip_address(url.hostname)
        return address.is_loopback or any(address in network for network in (
            ipaddress.ip_network('10.0.0.0/8'), ipaddress.ip_network('172.16.0.0/12'),
            ipaddress.ip_network('192.168.0.0/16'), ipaddress.ip_network('fc00::/7')))
    except ValueError:
        return False


def main():
    base_url = os.environ.pop('CLAUDER_OPENAI_BASE_URL')
    api_key = os.environ.pop('CLAUDER_OPENAI_API_KEY')
    if not valid_base_url(base_url):
        raise SystemExit('OpenAI base URL must use HTTPS or a localhost/private-IP HTTP endpoint')
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    server.base_url, server.api_key = base_url, api_key
    server.local_token = secrets.token_urlsafe(32)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    local_env = {'ANTHROPIC_BASE_URL': f'http://127.0.0.1:{server.server_port}',
                 'ANTHROPIC_AUTH_TOKEN': server.local_token, 'ANTHROPIC_API_KEY': ''}
    env = {**os.environ, **local_env}
    args, settings = session_settings(sys.argv[1:], local_env)
    # A per-session settings override wins over the shared provider settings.
    # Only the random local credential is written; upstream credentials stay in memory.
    with tempfile.TemporaryDirectory(prefix='clauder-openai-') as directory:
        path = os.path.join(directory, 'settings.json')
        with open(path, 'w') as handle:
            json.dump(settings, handle)
        os.chmod(path, 0o600)
        child = None
        previous = {}
        def forward(signum, frame):
            if child is not None and child.poll() is None:
                child.send_signal(signum)
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            previous[sig] = signal.signal(sig, forward)
        try:
            child = subprocess.Popen([*args, '--settings', path], env=env)
            code = child.wait()
        finally:
            if child is not None and child.poll() is None:
                child.terminate()
                child.wait(timeout=10)
            server.shutdown()
            server.server_close()
            for sig, handler in previous.items():
                signal.signal(sig, handler)
    return code if code >= 0 else 128 - code


if __name__ == '__main__':
    sys.exit(main())
