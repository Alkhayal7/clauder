# clauder

PATH-based wrapper for the Claude Code CLI that adds provider switching (Kimi, GLM, Qwen, etc.) without modifying the official binary.

When a provider is selected, credentials are written to `~/.claude/settings.json`. When running plain `claude` (no provider), any previously injected provider config is removed automatically.

## Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) must be installed before running the setup script:
  ```bash
  curl -fsSL https://claude.ai/install.sh | bash
  ```

## Install

```bash
git clone https://github.com/Alkhayal7/clauder.git
cd clauder
bash cc-switch.sh
```

This will:
1. Add `~/bin` to PATH
2. Write the wrapper to `~/bin/claude`
3. Create a sample `~/.claude_providers.ini` if missing

After install, open a new terminal or run `source ~/.bashrc` (or `~/.zshrc`). Run `hash -r` if needed.

## Configuration

Edit `~/.claude_providers.ini` (override path with `CLAUDE_CONF=/path/to/file`):

```ini
[kimi]
ANTHROPIC_AUTH_TOKEN=sk-xxxxxxxxxxxxxxxx
ANTHROPIC_BASE_URL=https://api.kimi.com/coding/
ANTHROPIC_DEFAULT_SONNET_MODEL=kimi-for-coding
ANTHROPIC_DEFAULT_HAIKU_MODEL=kimi-for-coding
ANTHROPIC_DEFAULT_OPUS_MODEL=kimi-for-coding

[glm]
ANTHROPIC_AUTH_TOKEN=sk-xxxxxxxxxxxxxxxx
ANTHROPIC_BASE_URL=https://open.bigmodel.cn/api/anthropic/
ANTHROPIC_DEFAULT_SONNET_MODEL=glm-4.7
ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-4.7
ANTHROPIC_DEFAULT_OPUS_MODEL=glm-4.7
```

`ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_BASE_URL` are required. The model keys are optional.

## Usage

```bash
claude                # default Anthropic Claude (cleans provider env from settings)
claude kimi           # use kimi provider
claude glm            # use glm provider
claude --list         # list configured providers
```

## Maintenance

```bash
bash cc-switch.sh update             # update the wrapper
bash cc-switch.sh status             # show diagnostics
bash cc-switch.sh uninstall          # remove wrapper
bash cc-switch.sh uninstall --purge  # remove wrapper and config
```

## Troubleshooting

- `claude` not resolving to `~/bin/claude`: open a new terminal, source your shell rc, or run `hash -r`.
- Set `CLAUDE_SWITCH_DEBUG=1` for verbose output.
