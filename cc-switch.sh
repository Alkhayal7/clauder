#!/usr/bin/env bash
set -euo pipefail

# ========================
# Config
# ========================
TARGET_HOME="${HOME}"
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
  ALT_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  [ -n "$ALT_HOME" ] && TARGET_HOME="$ALT_HOME"
fi

WRAPPER_PATH="${TARGET_HOME}/bin/claude"
CONF_PATH="${TARGET_HOME}/.claude_providers.ini"
DEBUG_FLAG="${CLAUDE_SWITCH_DEBUG:-0}"

# ========================
# Colors
# ========================
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
CYAN="\033[0;36m"
BOLD="\033[1m"
NC="\033[0m"

[ "$DEBUG_FLAG" != "0" ] && set -x

# ========================
# Helpers
# ========================
msg()  { printf "${GREEN}%s${NC}\n" "$*"; }
warn() { printf "${YELLOW}%s${NC}\n" "$*"; }
err()  { printf "${RED}%s${NC}\n" "$*" >&2; }
dbg()  {
  if [ "$DEBUG_FLAG" != "0" ]; then
    printf "[DEBUG] %s\n" "$*" >&2
  fi
  return 0
}
have_cmd() { command -v "$1" >/dev/null 2>&1; }

find_claude_on_path() {
  local self_path="$1"
  local entry candidate
  local -a path_entries
  IFS=':' read -r -a path_entries <<< "${PATH:-}"
  for entry in "${path_entries[@]}"; do
    [ -z "$entry" ] && continue
    candidate="${entry%/}/claude"
    if [ -x "$candidate" ] && [ "$candidate" != "$self_path" ]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

find_claude_executable() {
  local self_path="$1"
  local candidate
  local known=(
    "${HOME}/.local/bin/claude"
    "${HOME}/.claude/bin/claude"
    "/usr/local/bin/claude"
    "/usr/bin/claude"
    "/opt/homebrew/bin/claude"
  )
  for candidate in "${known[@]}"; do
    if [ -x "$candidate" ] && [ "$candidate" != "$self_path" ]; then
      echo "$candidate"
      return 0
    fi
  done
  if candidate="$(find_claude_on_path "$self_path")"; then
    echo "$candidate"
    return 0
  fi
  return 1
}

ensure_line_last() {
  # ensure_line_last <file> <line> [legacy_line]
  local f="$1" line="$2" legacy="${3:-}"
  [ -f "$f" ] || touch "$f"
  local tmp="${f}.tmp.$$"
  if [[ -n "$legacy" ]]; then
    awk -v line="$line" -v legacy="$legacy" '$0 != line && $0 != legacy {print} END {print line}' "$f" > "$tmp"
  else
    awk -v line="$line" '$0 != line {print} END {print line}' "$f" > "$tmp"
  fi
  mv "$tmp" "$f"
}

detect_shell_rc() {
  if [ -n "${ZSH_VERSION:-}" ]; then
    echo "${TARGET_HOME}/.zshrc"
  elif [ -n "${BASH_VERSION:-}" ]; then
    echo "${TARGET_HOME}/.bashrc"
  else
    echo "${TARGET_HOME}/.bashrc"
  fi
}

ensure_path_prefix() {
  local rc; rc="$(detect_shell_rc)"
  mkdir -p "${TARGET_HOME}/bin"
  local export_line='export PATH="$HOME/bin:$PATH"'
  local legacy_line='export PATH="$TARGET_HOME/bin:$PATH"'
  local targets=("$rc")
  # idempotent patch to common rc files
  [ "$rc" != "${TARGET_HOME}/.bashrc" ] && targets+=("${TARGET_HOME}/.bashrc")
  [ "$rc" != "${TARGET_HOME}/.zshrc" ] && targets+=("${TARGET_HOME}/.zshrc")
  [ -f "${TARGET_HOME}/.profile" ] && targets+=("${TARGET_HOME}/.profile")
  [ -f "${TARGET_HOME}/.bash_profile" ] && targets+=("${TARGET_HOME}/.bash_profile")
  [ -f "${TARGET_HOME}/.bash_login" ] && targets+=("${TARGET_HOME}/.bash_login")
  for target in "${targets[@]}"; do
    ensure_line_last "$target" "$export_line" "$legacy_line"
  done
  export PATH="${TARGET_HOME}/bin:$PATH"
}

# ------------------------
# Wrapper
# ------------------------
write_wrapper() {
  local tmp="${WRAPPER_PATH}.tmp.$$"
  cat > "$tmp" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

CONFIG="${CLAUDE_CONF:-$HOME/.claude_providers.ini}"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS_PATH="${CLAUDE_DIR}/settings.json"

# Keys older versions of this wrapper injected into settings.json. Always
# cleaned up, even if the section that introduced them is gone from the config.
LEGACY_ENV_KEYS='ANTHROPIC_API_KEY
ANTHROPIC_AUTH_TOKEN
ANTHROPIC_BASE_URL
ANTHROPIC_DEFAULT_SONNET_MODEL
ANTHROPIC_DEFAULT_HAIKU_MODEL
ANTHROPIC_DEFAULT_OPUS_MODEL'

# Wrapper directives and legacy aliases: consumed here or translated into an
# ANTHROPIC_* name, never exported to settings.json verbatim.
is_config_only_key() {
  case "$1" in
    CLAUDE_CONFIG_DIR|API_KEY|BASE_URL|MODEL|SMALL_FAST_MODE|ANTHROPIC_MODEL|ANTHROPIC_SMALL_FAST_MODE) return 0 ;;
    *) return 1 ;;
  esac
}

# Print every KEY=VALUE of one section. Splits on the first '=' so values may
# contain '=', and strips one layer of surrounding quotes so both
# KEY=value and KEY="value" mean the same thing.
read_section() {
  local section="$1"
  awk -v sec="[$section]" '
    BEGIN { q = sprintf("%c", 39) }
    function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    {
      t = trim($0)
      if (t ~ /^\[.*\]$/) { f = (t == sec); next }
      if (!f || t == "" || t ~ /^[#;]/) next
      i = index(t, "=")
      if (i < 2) next
      k = trim(substr(t, 1, i - 1))
      v = trim(substr(t, i + 1))
      if (length(v) > 1) {
        a = substr(v, 1, 1); b = substr(v, length(v), 1)
        if ((a == "\"" && b == "\"") || (a == q && b == q)) v = substr(v, 2, length(v) - 2)
      }
      if (k != "") print k "=" v
    }
  ' "$CONFIG" 2>/dev/null
}

# Look up one key in the blob produced by read_section.
section_get() {
  printf '%s\n' "$1" | awk -v key="$2" '
    { i = index($0, "="); if (i > 1 && substr($0, 1, i - 1) == key) { print substr($0, i + 1); exit } }
  '
}

# Every key used anywhere in the config: the set this wrapper is allowed to
# manage, so switching providers drops keys the new section does not define.
managed_keys() {
  printf '%s\n' "$LEGACY_ENV_KEYS"
  awk '
    function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    {
      t = trim($0)
      if (t ~ /^\[.*\]$/ || t == "" || t ~ /^[#;]/) next
      i = index(t, "=")
      if (i < 2) next
      k = trim(substr(t, 1, i - 1))
      if (k == "" || k == "CLAUDE_CONFIG_DIR") next
      if (!(k in seen)) { seen[k] = 1; print k }
    }
  ' "$CONFIG" 2>/dev/null
}

# apply_settings <settings_path> [provider_env_blob]
# Rewrites the managed env keys in settings.json. An empty blob just cleans.
apply_settings() {
  SETTINGS_FILE="$1" PROVIDER_ENV="${2:-}" REMOVE_KEYS="$(managed_keys)" node <<'NODE'
const fs = require('fs');
const path = require('path');

const settingsPath = process.env.SETTINGS_FILE;
const lines = (raw) => (raw || '').split('\n').map((l) => l.trim()).filter(Boolean);

const envUpdates = {};
for (const line of lines(process.env.PROVIDER_ENV)) {
  const i = line.indexOf('=');
  if (i < 1) continue;
  const key = line.slice(0, i).trim();
  const value = line.slice(i + 1);
  if (key && value !== '') envUpdates[key] = value;
}
const removeKeys = lines(process.env.REMOVE_KEYS);
const isProvider = Object.keys(envUpdates).length > 0;

let raw = '';
if (fs.existsSync(settingsPath)) {
  raw = fs.readFileSync(settingsPath, 'utf8');
}

let data = {};
if (raw.trim()) {
  try {
    data = JSON.parse(raw);
  } catch (err) {
    console.error(`✖ Failed to parse ${settingsPath}: ${err.message}`);
    process.exit(1);
  }
}

data.env = { ...(data.env || {}) };
for (const key of removeKeys) delete data.env[key];
Object.assign(data.env, envUpdates);
if (Object.keys(data.env).length === 0) delete data.env;

if (isProvider) {
  if (!data.permissions) data.permissions = { allow: [], deny: [] };
  if (typeof data.alwaysThinkingEnabled === 'undefined') data.alwaysThinkingEnabled = true;
}

const next = JSON.stringify(data, null, 2);
if (next !== raw) {
  fs.mkdirSync(path.dirname(settingsPath), { recursive: true });
  fs.writeFileSync(settingsPath, next);
}
NODE
}

get_ini_value() {
  section_get "$(read_section "$1")" "$2"
}

# ---- --list providers ----
if [[ "${1:-}" == "--list" ]]; then
  if [[ -f "$CONFIG" ]]; then
    echo "Available Claude providers/accounts in $CONFIG:"
    awk '
      BEGIN { q = sprintf("%c", 39) }
      function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
      function flush() {
        if (sec != "") {
          if (dir != "") printf "  - %s  (account: %s)\n", sec, dir
          else printf "  - %s\n", sec
        }
      }
      {
        t = trim($0)
        if (t ~ /^\[.*\]$/) { flush(); sec = substr(t, 2, length(t) - 2); dir = ""; next }
        i = index(t, "=")
        if (i < 2 || trim(substr(t, 1, i - 1)) != "CLAUDE_CONFIG_DIR") next
        v = trim(substr(t, i + 1))
        if (length(v) > 1) {
          a = substr(v, 1, 1); b = substr(v, length(v), 1)
          if ((a == "\"" && b == "\"") || (a == q && b == q)) v = substr(v, 2, length(v) - 2)
        }
        dir = v
      }
      END { flush() }
    ' "$CONFIG"
  else
    echo "Config file not found: $CONFIG"
  fi
  # Accounts: the default login (~/.claude) plus any created via 'claude @<name>'
  echo ""
  echo "Accounts:"
  if [[ -d "$HOME/.claude" ]]; then
    echo "  - (default)  ~/.claude   # plain 'claude' with no @name"
  else
    echo "  - (default)  ~/.claude   # plain 'claude'; created on first run"
  fi
  shopt -s nullglob
  adhoc=("$HOME"/.claude-*)
  shopt -u nullglob
  for d in "${adhoc[@]}"; do
    [ -d "$d" ] || continue
    name="${d##*/.claude-}"
    printf "  - @%-8s ~/.claude-%s\n" "$name" "$name"
  done
  echo ""
  echo "Usage: claude [args...]                    # default account (~/.claude)"
  echo "       claude <provider> [args...]         # default account, switch provider"
  echo "       claude @<name> [provider] [args...] # named account in ~/.claude-<name>"
  exit 0
fi

run_claude() {
  # Locate the official CLI (absolute paths to avoid recursion) and exec it
  local self_path
  self_path="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

  local entry candidate
  local -a path_entries candidates
  candidates=(
    "$HOME/.local/bin/claude"
    "$HOME/.claude/bin/claude"
    "/usr/local/bin/claude"
    "/usr/bin/claude"
    "/opt/homebrew/bin/claude"
  )
  IFS=':' read -r -a path_entries <<< "${PATH:-}"
  for entry in "${path_entries[@]}"; do
    [ -z "$entry" ] && continue
    candidate="${entry%/}/claude"
    if [[ -x "$candidate" && "$candidate" != "$self_path" ]]; then
      candidates+=("$candidate")
      break
    fi
  done

  local p
  for p in "${candidates[@]}"; do
    if [[ -x "$p" && "$p" != "$self_path" ]]; then
      exec "$p" "$@"
    fi
  done

  echo "Official Claude CLI not found. Please install: curl -fsSL https://claude.ai/install.sh | bash" >&2
  exit 1
}

# ---- dynamic accounts: claude @<name> [provider] [args...] ----
# Each account keeps its own login/settings in ~/.claude-<name>, created on
# first use. Any number of accounts can run side by side.
account=""
if [[ "${1:-}" =~ ^@([a-zA-Z0-9_-]+)$ ]]; then
  account="${BASH_REMATCH[1]}"
  shift
  export CLAUDE_CONFIG_DIR="$HOME/.claude-${account}"
  mkdir -p "$CLAUDE_CONFIG_DIR"
  CLAUDE_DIR="$CLAUDE_CONFIG_DIR"
  SETTINGS_PATH="${CLAUDE_DIR}/settings.json"
  echo ">>> Using account: @${account} (${CLAUDE_CONFIG_DIR})" >&2
fi

# ---- check if first arg is a valid provider/account section ----
provider=""
maybe_provider="${1:-}"
if [[ -n "$maybe_provider" && "$maybe_provider" != -* && "$maybe_provider" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  # Check if it matches a section in the config
  if [[ -f "$CONFIG" ]] && grep -qE "^[[:space:]]*\[${maybe_provider}\][[:space:]]*$" "$CONFIG" 2>/dev/null; then
    provider="$maybe_provider"
    shift
  fi
fi

if [[ -n "$provider" ]]; then
  section="$(read_section "$provider")"

  # ---- account support: a section may pin its own CLAUDE_CONFIG_DIR so
  # separate logins (e.g. work/personal) can run side by side ----
  config_dir=$(section_get "$section" "CLAUDE_CONFIG_DIR")
  if [[ -n "${config_dir:-}" ]]; then
    config_dir="${config_dir/#\~/$HOME}"
    export CLAUDE_CONFIG_DIR="$config_dir"
    mkdir -p "$config_dir"
    CLAUDE_DIR="$config_dir"
    SETTINGS_PATH="${CLAUDE_DIR}/settings.json"
    echo ">>> Using account: ${provider} (${CLAUDE_CONFIG_DIR})" >&2
  fi

  api_key=$(section_get "$section" "ANTHROPIC_API_KEY")
  auth_token=$(section_get "$section" "ANTHROPIC_AUTH_TOKEN")
  [[ -z "${auth_token:-}" ]] && auth_token=$(section_get "$section" "API_KEY") # backward compat

  base_url=$(section_get "$section" "ANTHROPIC_BASE_URL")
  [[ -z "${base_url:-}" ]] && base_url=$(section_get "$section" "BASE_URL") # backward compat

  default_sonnet=$(section_get "$section" "ANTHROPIC_DEFAULT_SONNET_MODEL")
  default_haiku=$(section_get "$section" "ANTHROPIC_DEFAULT_HAIKU_MODEL")
  default_opus=$(section_get "$section" "ANTHROPIC_DEFAULT_OPUS_MODEL")

  legacy_model=$(section_get "$section" "ANTHROPIC_MODEL")
  [[ -z "${legacy_model:-}" ]] && legacy_model=$(section_get "$section" "MODEL")

  legacy_small_fast=$(section_get "$section" "ANTHROPIC_SMALL_FAST_MODE")
  [[ -z "${legacy_small_fast:-}" ]] && legacy_small_fast=$(section_get "$section" "SMALL_FAST_MODE")

  [[ -z "${default_sonnet:-}" ]] && default_sonnet="$legacy_model"
  [[ -z "${default_haiku:-}" ]] && default_haiku="$legacy_small_fast"
  [[ -z "${default_haiku:-}" ]] && default_haiku="$legacy_model"
  [[ -z "${default_opus:-}" ]] && default_opus="$legacy_model"

  if [[ -n "${api_key:-}" && -n "${auth_token:-}" ]]; then
    printf "✖ Provider [%s] sets both ANTHROPIC_API_KEY and ANTHROPIC_AUTH_TOKEN; choose the authentication scheme required by the provider.\n" "$provider" >&2
    exit 1
  fi

  if [[ -z "${api_key:-}" && -z "${auth_token:-}" && -z "${base_url:-}" ]]; then
    if [[ -n "${config_dir:-}" ]]; then
      # Account-only section: official Anthropic login isolated in its own
      # config dir. Make sure no leftover provider env shadows the login.
      apply_settings "$SETTINGS_PATH"
      run_claude "$@"
    fi
    printf "✖ Section [%s] defines neither provider keys nor CLAUDE_CONFIG_DIR.\n" "$provider" >&2
    exit 1
  fi

  missing=()
  [[ -z "${api_key:-}" && -z "${auth_token:-}" ]] && missing+=("ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN")
  [[ -z "${base_url:-}" ]] && missing+=("ANTHROPIC_BASE_URL")

  if (( ${#missing[@]} > 0 )); then
    printf "✖ Provider [%s] has incomplete config (missing: %s).\n" "$provider" "$(IFS=,; echo "${missing[*]}")" >&2
    exit 1
  fi

  # Any other key in the section (ANTHROPIC_CUSTOM_HEADERS,
  # CLAUDE_CODE_SUBAGENT_MODEL, ...) is passed through to settings.json as-is;
  # the resolved values below are appended last so aliases win over raw keys.
  provider_env=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    key="${line%%=*}"
    if is_config_only_key "$key"; then continue; fi
    provider_env+="${line}"$'\n'
  done <<< "$section"

  provider_env+="ANTHROPIC_API_KEY=${api_key}"$'\n'
  provider_env+="ANTHROPIC_AUTH_TOKEN=${auth_token}"$'\n'
  provider_env+="ANTHROPIC_BASE_URL=${base_url}"$'\n'
  provider_env+="ANTHROPIC_DEFAULT_SONNET_MODEL=${default_sonnet}"$'\n'
  provider_env+="ANTHROPIC_DEFAULT_HAIKU_MODEL=${default_haiku}"$'\n'
  provider_env+="ANTHROPIC_DEFAULT_OPUS_MODEL=${default_opus}"$'\n'

  apply_settings "$SETTINGS_PATH" "$provider_env"
  echo ">>> Using provider: ${provider}" >&2
else
  # No provider — remove any previously injected provider env keys from settings.json
  apply_settings "$SETTINGS_PATH"
fi

# ---- locate official CLI and run it ----
run_claude "$@"
SH

  mkdir -p "$(dirname "$WRAPPER_PATH")"
  mv -f "$tmp" "$WRAPPER_PATH"
  chown "$USER":"$USER" "$WRAPPER_PATH" 2>/dev/null || true
  chmod +x "$WRAPPER_PATH"
}

write_sample_conf_if_absent() {
  if [ -f "$CONF_PATH" ]; then
    warn "Config already exists: $CONF_PATH (leaving it untouched)."
    return 0
  fi
  cat > "$CONF_PATH" <<'INI'
# Providers (Anthropic-compatible API)
# Usage: claude <provider_name> [args...]
#        claude [args...] (uses official Anthropic Claude)
#
# Any other key in a section is written to settings.json as-is, e.g.
# CLAUDE_CODE_SUBAGENT_MODEL or ANTHROPIC_CUSTOM_HEADERS. Quotes around a
# value are optional and stripped, so KEY=value and KEY="value" are the same.

# Accounts — run multiple Claude Code logins side by side.
# A section with CLAUDE_CONFIG_DIR keeps its own login/settings in that folder.
# First run of 'claude work' will prompt you to log in with that account.
#
# [work]
# CLAUDE_CONFIG_DIR=~/.claude-work
#
# [personal]
# CLAUDE_CONFIG_DIR=~/.claude-personal

[kimi]
ANTHROPIC_AUTH_TOKEN=sk-xxxxxxxxxxxxxxxx
ANTHROPIC_BASE_URL=https://api.kimi.com/coding/
ANTHROPIC_DEFAULT_SONNET_MODEL=kimi-k2.5
ANTHROPIC_DEFAULT_HAIKU_MODEL=kimi-k2.5
ANTHROPIC_DEFAULT_OPUS_MODEL=kimi-k2.5

[glm]
ANTHROPIC_AUTH_TOKEN=sk-xxxxxxxxxxxxxxxx
ANTHROPIC_BASE_URL=https://open.bigmodel.cn/api/anthropic/
ANTHROPIC_DEFAULT_SONNET_MODEL=glm-5
ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-5
ANTHROPIC_DEFAULT_OPUS_MODEL=glm-5

[deepseek]
ANTHROPIC_AUTH_TOKEN=sk-xxxxxxxxxxxxxxxx
ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic
ANTHROPIC_DEFAULT_SONNET_MODEL=deepseek-v4-flash
ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek-v4-flash
ANTHROPIC_DEFAULT_OPUS_MODEL=deepseek-v4-pro

[go]
ANTHROPIC_API_KEY=sk-xxxxxxxxxxxxxxxx
ANTHROPIC_BASE_URL=https://opencode.ai/zen/go
ANTHROPIC_DEFAULT_SONNET_MODEL=deepseek-v4-flash
ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek-v4-flash
ANTHROPIC_DEFAULT_OPUS_MODEL=deepseek-v4-pro
INI
  chmod 600 "$CONF_PATH" || true
}

# ------------------------
# Status (colored)
# ------------------------
cmd_status() {
  echo -e "${BOLD}Claude Wrapper Status${NC}"
  echo "---------------------"

  # claude command path
  local CLAUDE_PATH
  CLAUDE_PATH="$(command -v claude 2>/dev/null || true)"
  if [[ -n "$CLAUDE_PATH" && -x "$CLAUDE_PATH" ]]; then
    echo -e "claude command path: ${GREEN}${CLAUDE_PATH}${NC}"
  else
    echo -e "claude command path: ${RED}<not found>${NC}"
  fi

  # wrapper file
  if [[ -f "$WRAPPER_PATH" ]]; then
    echo -e "Wrapper file exists: ${GREEN}Yes${NC} (${WRAPPER_PATH})"
  else
    echo -e "Wrapper file exists: ${RED}No${NC} (expected at ${WRAPPER_PATH})"
  fi

  # config file and providers list
  if [[ -f "$CONF_PATH" ]]; then
    echo -e "Config file path: ${GREEN}${CONF_PATH}${NC}"
    local PROVS
    PROVS="$(grep -E '^\[.*\]' "$CONF_PATH" | sed 's/[][]//g' | paste -sd',' -)"
    if [[ -n "$PROVS" ]]; then
      echo -e "Providers available: ${YELLOW}${PROVS}${NC}"
    else
      echo -e "Providers available: ${RED}<none>${NC}"
    fi
  else
    echo -e "Config file path: ${RED}<not found>${NC} (expected at ${CONF_PATH})"
  fi

  local SETTINGS_FILE="${HOME}/.claude/settings.json"
  if [[ -f "$SETTINGS_FILE" ]]; then
    echo -e "settings.json path: ${GREEN}${SETTINGS_FILE}${NC}"
  else
    echo -e "settings.json path: ${YELLOW}${SETTINGS_FILE}${NC} (will be created on first claude run)"
  fi
}

# ------------------------
# Update & Uninstall
# ------------------------
cmd_update() {
  msg "Updating wrapper..."
  ensure_path_prefix
  write_wrapper
  msg "Wrapper updated."
}

cmd_uninstall() {
  local PURGE=0
  if [[ "${1:-}" == "--purge" ]]; then
    PURGE=1
  fi

  read -r -p "Are you sure you want to uninstall the Claude wrapper? [y/N]: " ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) warn "Uninstall cancelled."; exit 0 ;;
  esac

  if [ -f "${WRAPPER_PATH}" ]; then
    echo "Removing wrapper at ${WRAPPER_PATH}..."
    rm -f "${WRAPPER_PATH}"
    msg "Removed wrapper."
  else
    warn "Wrapper not found at ${WRAPPER_PATH}."
  fi

  if [ "$PURGE" -eq 1 ]; then
    if [ -f "${CONF_PATH}" ]; then
      read -r -p "Also remove config ${CONF_PATH}? [y/N]: " ans2
      case "$ans2" in
        y|Y|yes|YES) rm -f "${CONF_PATH}"; msg "Removed config." ;;
        *) warn "Skipped config removal." ;;
      esac
    else
      warn "Config not found; nothing to purge."
    fi
  fi

  warn "Note: PATH line in your shell rc was not removed (manual cleanup if desired)."
}

verify() {
  msg "Verification:"
  echo -e "Resolved 'claude' in PATH: ${CYAN}$(command -v claude || echo '<not found>')${NC}"
  if command -v claude >/dev/null 2>&1; then
    echo -e "${BOLD}Providers:${NC}"
    claude --list || true
  fi
}

# ========================
# Main (subcommands)
# ========================
CMD="install"
for a in "$@"; do
  case "$a" in
    install|update|uninstall|status) CMD="$a" ;;
    --purge) ;; # handled in cmd_uninstall
    -h|--help)
      cat <<EOF
Usage:
  $0 [command] [options]

Commands:
  install     Install or reinstall the wrapper (default if omitted)
  update      Update the wrapper to the latest version of this script
  uninstall   Remove the wrapper; optional --purge also removes config
  status      Show current resolution and config path

Options:
  --purge     With uninstall, also remove ${CONF_PATH}
  -h, --help  Show this help message
EOF
      exit 0 ;;
    *) ;;
  esac
done

case "$CMD" in
  install)
    msg "Step 1/3: Ensuring ~/bin in PATH..."
    ensure_path_prefix
    msg "Step 2/3: Writing wrapper..."
    write_wrapper
    msg "Step 3/3: Writing sample config (if missing)..."
    write_sample_conf_if_absent
    msg "Installation complete."
    echo "Next: open a new terminal or source your shell rc (e.g., 'source ~/.bashrc'), then test 'claude --list'."
    verify
    ;;
  update)
    cmd_update
    ;;
  uninstall)
    cmd_uninstall "${2:-}"
    ;;
  status)
    cmd_status
    ;;
  *)
    err "Unknown command: $CMD" ;;
esac
