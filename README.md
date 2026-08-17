# clauder

A wrapper for the Claude Code CLI that adds provider switching (Kimi, GLM, Qwen, etc.) and multi-account support without modifying the official binary. Works on macOS, Linux (Bash/Zsh), and Windows (PowerShell).

When a provider is selected, credentials are written to `~/.claude/settings.json`. When running plain `claude` (no provider), any previously injected provider config is removed automatically. Accounts isolate each login in its own folder, so you can run several Claude accounts (e.g. work and personal) at the same time.

## Prerequisites

The [Claude Code CLI](https://code.claude.com/docs/en/quickstart) must be installed before running the setup script.

- **macOS / Linux:**
  ```bash
  curl -fsSL https://claude.ai/install.sh | bash
  ```
- **Windows:**
  ```powershell
  winget install Anthropic.ClaudeCode
  ```

## Install

**macOS / Linux (Bash/Zsh):**

```bash
git clone https://github.com/Alkhayal7/clauder.git
cd clauder
bash cc-switch.sh
```

Adds `~/bin` to PATH and writes the wrapper to `~/bin/claude`. Then open a new terminal or run `source ~/.bashrc` (or `~/.zshrc`); run `hash -r` if needed.

**Windows (PowerShell):**

```powershell
git clone https://github.com/Alkhayal7/clauder.git
cd clauder
./cc-switch.ps1
```

Writes the wrapper to `~/.clauder` and sources it from your PowerShell profile. Then open a new terminal (or run `. $PROFILE`).

If you get "running scripts is disabled on this system", enable local scripts once:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

Both installers create a sample `~/.claude_providers.ini` if one doesn't exist.

## Configuration

Edit `~/.claude_providers.ini` (override path with `CLAUDE_CONF=/path/to/file`). On Windows this is `C:\Users\<you>\.claude_providers.ini` — open it with `notepad $HOME\.claude_providers.ini`.

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

[go]
ANTHROPIC_API_KEY=sk-xxxxxxxxxxxxxxxx
ANTHROPIC_BASE_URL=https://opencode.ai/zen/go
ANTHROPIC_DEFAULT_SONNET_MODEL=deepseek-v4-flash
ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek-v4-flash
ANTHROPIC_DEFAULT_OPUS_MODEL=deepseek-v4-flash
```

Set exactly one credential key and provide `ANTHROPIC_BASE_URL`:

- `ANTHROPIC_API_KEY` sends the credential as `X-Api-Key` (for example, OpenCode Go).
- `ANTHROPIC_AUTH_TOKEN` sends the credential as `Authorization: Bearer`.

The model keys are optional. For OpenCode Go, omit `/v1` from the base URL because Claude Code appends the API path.

### Accounts

Prefix any name with `@` to run it as a separate account, stored in its own `~/.claude-<name>` folder (created on first use). Plain `claude` is the default account (`~/.claude`). Each account has its own login, so you can run several at once in separate terminals.

```bash
claude              # default account (~/.claude)
claude @work        # 'work' account (~/.claude-work)
claude @work kimi   # 'work' account, using the kimi provider
```

> On Windows PowerShell, quote the name so it isn't read as splatting: `claude "@work"`.

## Usage

```bash
claude                # default account, official Anthropic Claude
claude kimi           # switch provider (kimi, glm, ...)
claude go             # OpenCode Go, using the [go] section
claude @work          # named account in ~/.claude-work
claude @work kimi     # named account with a provider
claude --list         # list providers and accounts
```

## Maintenance

```bash
# macOS / Linux
bash cc-switch.sh update             # update the wrapper
bash cc-switch.sh status             # show diagnostics
bash cc-switch.sh uninstall          # remove wrapper
bash cc-switch.sh uninstall --purge  # remove wrapper and config
```

hi abdo 👋❤️
