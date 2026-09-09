import http.server
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import threading
import unittest
import urllib.error
import urllib.request

spec = importlib.util.spec_from_file_location('adapter', Path(__file__).resolve().parents[1] / 'openai-adapter.py')
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)


class TranslationTests(unittest.TestCase):
    def test_private_lan_endpoints(self):
        for url in ['http://192.168.0.170:4009/v1', 'http://127.0.0.1:4009/v1',
                    'http://10.0.0.1/v1', 'https://api.example.com/v1']:
            self.assertTrue(adapter.valid_base_url(url), url)
        for url in ['http://localhost.evil.com/v1', 'http://8.8.8.8/v1',
                    'https://', 'file:///tmp/api', 'http://user:pass@localhost/v1']:
            self.assertFalse(adapter.valid_base_url(url), url)

    def test_null_cache_usage(self):
        self.assertEqual(adapter.usage_from_openai({'prompt_tokens': 71,
            'completion_tokens': 34, 'prompt_tokens_details': None}),
            {'input_tokens': 71, 'output_tokens': 34,
             'cache_read_input_tokens': 0, 'cache_creation_input_tokens': 0})

    def test_caller_settings_are_preserved(self):
        args, settings = adapter.session_settings(['claude', '--settings',
            '{"model":"sonnet","env":{"CUSTOM":"yes","ANTHROPIC_BASE_URL":"old"}}', '-p', 'hello'],
            {'ANTHROPIC_BASE_URL': 'local'})
        self.assertEqual(args, ['claude', '-p', 'hello'])
        self.assertEqual(settings['model'], 'sonnet')
        self.assertEqual(settings['env'], {'CUSTOM': 'yes', 'ANTHROPIC_BASE_URL': 'local'})

    def test_long_tool_names_are_stable_and_distinct(self):
        name = 'mcp__' + 'long_server_' * 8 + 'read'
        encoded = adapter.tool_name(name)
        self.assertEqual(len(encoded), 64)
        self.assertEqual(encoded, adapter.tool_name(name))
        self.assertNotEqual(encoded, adapter.tool_name(name + '2'))
        self.assertEqual(adapter.tool_name('Bash'), 'Bash')
        result = adapter.translate_request({'model': 'x', 'messages': [],
            'tools': [{'name': name, 'input_schema': {'type': 'object'}}],
            'tool_choice': {'type': 'tool', 'name': name}})
        self.assertEqual(result['tools'][0]['function']['name'], encoded)
        self.assertEqual(result['tool_choice']['function']['name'], encoded)

    def test_tool_history_and_image(self):
        result = adapter.translate_request({'model': 'example[1m]', 'system': [{'type': 'text', 'text': 'system'}],
            'messages': [
                {'role': 'assistant', 'content': [{'type': 'thinking', 'thinking': 'private'},
                    {'type': 'tool_use', 'id': 'call_1', 'name': 'Read', 'input': {'path': 'a'}}]},
                {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': 'call_1', 'content': [{'type': 'text', 'text': 'contents'}]},
                    {'type': 'image', 'source': {'type': 'base64', 'media_type': 'image/png', 'data': 'abc'}}]}],
            'tools': [{'name': 'Read', 'input_schema': {'type': 'object'}}],
            'tool_choice': {'type': 'any', 'disable_parallel_tool_use': True}})
        self.assertEqual(result['model'], 'example')
        self.assertEqual([m['role'] for m in result['messages']], ['system', 'assistant', 'tool', 'user'])
        self.assertEqual(result['messages'][2]['content'], 'contents')
        self.assertEqual(result['messages'][1]['tool_calls'][0]['function']['arguments'], '{"path": "a"}')
        self.assertEqual(result['messages'][3]['content'][0]['image_url']['url'], 'data:image/png;base64,abc')
        self.assertEqual(result['tool_choice'], 'required')
        self.assertFalse(result['parallel_tool_calls'])

    def test_unsupported_content_is_explicit(self):
        with self.assertRaisesRegex(ValueError, 'Unsupported content block'):
            adapter.translate_request({'model': 'x', 'messages': [{'role': 'user', 'content': [{'type': 'document'}]}]})

    def test_sse_comments_and_usage(self):
        raw = io.BytesIO(b': ping\n\ndata: {"choices": []}\n\ndata: [DONE]\n\n')
        self.assertEqual(list(adapter.stream_chunks(raw)), [{'choices': []}])
        self.assertEqual(adapter.usage_from_openai({'prompt_tokens': 20, 'completion_tokens': 3,
                         'prompt_tokens_details': {'cached_tokens': 15}})['input_tokens'], 5)


class LifecycleTests(unittest.TestCase):
    def test_session_override_and_cleanup(self):
        script = '''
import json, os, sys, urllib.request
path = sys.argv[sys.argv.index('--settings') + 1]
settings = json.load(open(path))
assert settings['model'] == 'sonnet'
assert 'CLAUDER_OPENAI_API_KEY' not in os.environ
url = os.environ['ANTHROPIC_BASE_URL']
request = urllib.request.Request(url + '/v1/messages/count_tokens',
    data=b'{"messages": []}', headers={'Authorization': 'Bearer ' + os.environ['ANTHROPIC_AUTH_TOKEN']})
with urllib.request.urlopen(request) as response:
    assert response.status == 200
print(json.dumps({'path': path, 'port': int(url.rsplit(':', 1)[1])}))
'''
        result = subprocess.run([sys.executable, str(Path(adapter.__file__)), sys.executable, '-c', script,
            '--settings', '{"model":"sonnet"}'],
            env={**os.environ, 'CLAUDER_OPENAI_BASE_URL': 'http://127.0.0.1:1/v1',
                 'CLAUDER_OPENAI_API_KEY': 'test-upstream'}, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        info = json.loads(result.stdout)
        self.assertFalse(Path(info['path']).exists())
        with socket.socket() as sock:
            self.assertNotEqual(sock.connect_ex(('127.0.0.1', info['port'])), 0)


class Upstream(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        self.server.payload = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.server.auth = self.headers['Authorization']
        if self.server.fail:
            data = b'{"error":{"message":"quota exceeded"}}'
            self.send_response(429)
        else:
            chunks = [
                {'choices': [{'index': 0, 'delta': {'content': 'Hello '}}]},
                {'choices': [{'index': 0, 'delta': {'content': 'world', 'tool_calls': [
                    {'index': 1, 'id': 'b', 'function': {'name': 'second', 'arguments': '{"b":'}},
                    {'index': 0, 'id': 'a', 'function': {'name': 'first', 'arguments': '{"a":'}}]}}]},
                {'choices': [{'index': 0, 'delta': {'tool_calls': [
                    {'index': 0, 'function': {'arguments': '1}'}},
                    {'index': 1, 'function': {'arguments': '2}'}}]}, 'finish_reason': 'tool_calls'}]},
                {'choices': [], 'usage': {'prompt_tokens': 25, 'completion_tokens': 8}},
            ]
            data = ''.join('data: ' + json.dumps(c) + '\n\n' for c in chunks).encode() + b'data: [DONE]\n\n'
            self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.upstream = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
        self.upstream.fail = False
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), adapter.Handler)
        self.server.base_url = f'http://127.0.0.1:{self.upstream.server_port}/v1'
        self.server.api_key = 'upstream-secret'
        self.server.local_token = 'local-secret'
        for server in [self.upstream, self.server]:
            threading.Thread(target=server.serve_forever, daemon=True).start()
        self.body = {'model': 'example', 'messages': [{'role': 'user', 'content': 'hello'}], 'max_tokens': 100}

    def tearDown(self):
        for server in [self.server, self.upstream]:
            server.shutdown()
            server.server_close()

    def request(self, stream=False, token='local-secret', path='/v1/messages?beta=true'):
        req = urllib.request.Request(f'http://127.0.0.1:{self.server.server_port}' + path,
            data=json.dumps({**self.body, 'stream': stream}).encode(), headers={'x-api-key': token})
        return urllib.request.urlopen(req, timeout=5)

    def test_streaming_tools_and_usage(self):
        with self.request(True) as response:
            events = list(adapter.stream_chunks(response))
        self.assertEqual(events[0]['type'], 'message_start')
        self.assertEqual(events[-1]['type'], 'message_stop')
        starts = [e for e in events if e['type'] == 'content_block_start']
        self.assertEqual([e['index'] for e in starts], [0, 1, 2])
        self.assertEqual([e['content_block'].get('name') for e in starts[1:]], ['first', 'second'])
        self.assertEqual(events[-2]['delta']['stop_reason'], 'tool_use')
        self.assertEqual(events[-2]['usage']['output_tokens'], 8)
        self.assertEqual(self.upstream.auth, 'Bearer upstream-secret')
        self.assertTrue(self.upstream.payload['stream'])

    def test_nonstream_tools(self):
        with self.request() as response:
            body = json.load(response)
        self.assertEqual(body['content'][0]['text'], 'Hello world')
        self.assertEqual(body['content'][1]['input'], {'a': 1})
        self.assertEqual(body['content'][2]['input'], {'b': 2})

    def test_auth_and_upstream_error(self):
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.request(token='wrong')
        self.assertEqual(caught.exception.code, 401)
        caught.exception.close()
        self.upstream.fail = True
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.request()
        self.assertEqual(caught.exception.code, 429)
        self.assertIn('quota exceeded', caught.exception.read().decode())
        caught.exception.close()

    def test_count_tokens(self):
        with self.request(path='/v1/messages/count_tokens') as response:
            self.assertGreater(json.load(response)['input_tokens'], 0)


if __name__ == '__main__':
    unittest.main()
