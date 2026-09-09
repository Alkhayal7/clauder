# clauder

Switch Claude Code providers and accounts. Supports macOS, Linux, and Windows. OpenAI-compatible providers require macOS/Linux and Python 3.9+.

## Install

Install [Claude Code](https://code.claude.com/docs/en/quickstart), then clone this repo:

```bash
git clone https://github.com/Alkhayal7/clauder.git
cd clauder
```

**macOS / Linux:**

```bash
bash cc-switch.sh
```

**Windows (PowerShell):**

```powershell
./cc-switch.ps1
```

Open a new terminal after installation. The installer creates `~/.claude_providers.ini` if missing.

## Configure

Edit `~/.claude_providers.ini` and add your API keys. More provider examples are in [claude_providers.ini](claude_providers.ini).

### OpenCode Go

```ini
[go]
ANTHROPIC_BASE_URL=https://opencode.ai/zen/go
ANTHROPIC_API_KEY=YOUR_OPENCODE_KEY
ANTHROPIC_DEFAULT_SONNET_MODEL=deepseek-v4-flash
ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek-v4-flash
ANTHROPIC_DEFAULT_OPUS_MODEL=deepseek-v4-pro
CLAUDE_CODE_SUBAGENT_MODEL=deepseek-v4-flash
CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000
CLAUDE_CODE_DISABLE_ARTIFACT=1
```

### TokenRouter / OpenAI-compatible

```ini
[tokenrouter]
API_FORMAT=openai
ANTHROPIC_BASE_URL=https://api.tokenrouter.com/v1
ANTHROPIC_API_KEY=YOUR_TOKENROUTER_KEY
ANTHROPIC_DEFAULT_SONNET_MODEL=z-ai/glm-5.3-free
ANTHROPIC_DEFAULT_HAIKU_MODEL=z-ai/glm-5.3-free
ANTHROPIC_DEFAULT_OPUS_MODEL=z-ai/glm-5.3-free
CLAUDE_CODE_SUBAGENT_MODEL=z-ai/glm-5.3-free
CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000
```

`API_FORMAT=openai` starts a local adapter automatically and stops it when Claude exits. It sends OpenAI Chat Completions requests with Bearer authentication. Keep `/v1` in the TokenRouter URL; omit it for OpenCode Go.

For Anthropic-compatible providers, use exactly one credential: `ANTHROPIC_API_KEY` for `X-Api-Key`, or `ANTHROPIC_AUTH_TOKEN` for Bearer authentication. Additional environment variables pass through to Claude settings. Override the config path with `CLAUDE_CONF`.

### Local model

```ini
[local]
API_FORMAT=openai
ANTHROPIC_BASE_URL=http://192.168.0.170:4009/v1
ANTHROPIC_API_KEY=local
ANTHROPIC_DEFAULT_SONNET_MODEL=openai/gpt-oss-20b
ANTHROPIC_DEFAULT_HAIKU_MODEL=openai/gpt-oss-20b
ANTHROPIC_DEFAULT_OPUS_MODEL=openai/gpt-oss-20b
CLAUDE_CODE_SUBAGENT_MODEL=openai/gpt-oss-20b
CLAUDE_CODE_MAX_CONTEXT_TOKENS=124000
```

Use your server's address and model ID. `local` is a placeholder key for servers without authentication; replace it if your server requires a key.

Set `CLAUDE_CODE_MAX_CONTEXT_TOKENS` per provider to control the context limit Claude uses for auto-compaction. Match your model or server limit, or choose a lower value; this does not increase the server’s capacity.

## Usage

```bash
claude                 # official Anthropic; clears provider settings
claude go              # OpenCode Go
claude tokenrouter     # TokenRouter through the OpenAI adapter
claude local           # local model through the OpenAI adapter
claude kimi            # any provider section in your config
claude @work           # separate account in ~/.claude-work
claude @work go         # separate account with a provider
claude --list          # list providers and accounts
```

In PowerShell, quote account names: `claude "@work"`.

## Update / Remove

```bash
bash cc-switch.sh update
bash cc-switch.sh status
bash cc-switch.sh uninstall
bash cc-switch.sh uninstall --purge  # also remove config
```

On Windows, rerun `./cc-switch.ps1` to update.

## Adapter limits

Streaming, tool calls, user images, and JSON-schema output are supported. Token counts are approximate; Anthropic reasoning settings are not forwarded. Documents, image tool results, and Anthropic server-side tools are unsupported.

Run tests: `python3 -m unittest discover -s tests -v`.
