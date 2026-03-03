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
CLAUDE_DIR="${HOME}/.claude"
SETTINGS_PATH="${CLAUDE_DIR}/settings.json"

get_ini_value() {
  local section="$1" key="$2"
  awk -F '=' -v sec="[$section]" -v key="$key" '
    $0==sec {f=1; next}
    /^\[/{f=0}
    f {
      k=$1; gsub(/^[ \t]+|[ \t]+$/, "", k)
      if (k==key) {
        v=$2; gsub(/^[ \t]+|[ \t]+$/, "", v)
        print v; exit
      }
    }
  ' "$CONFIG" 2>/dev/null
}

# ---- --list providers ----
if [[ "${1:-}" == "--list" ]]; then
  if [[ -f "$CONFIG" ]]; then
    echo "Available Claude providers in $CONFIG:"
    awk '
      /^\[.*\]/ {
        sec=substr($0,2,length($0)-2);
        printf "  - %s\n", sec
      }' "$CONFIG"
    echo ""
    echo "Usage: claude <provider> [args...]"
    echo "       claude [args...] (uses official Anthropic Claude)"
  else
    echo "Config file not found: $CONFIG"
    echo ""
    echo "Usage: claude [args...] (uses official Anthropic Claude)"
  fi
  exit 0
fi

# ---- check if first arg is a valid provider ----
provider=""
maybe_provider="${1:-}"
if [[ -n "$maybe_provider" && "$maybe_provider" != -* && "$maybe_provider" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  # Check if it matches a section in the config
  if [[ -f "$CONFIG" ]] && grep -qE "^\[${maybe_provider}\]$" "$CONFIG" 2>/dev/null; then
    provider="$maybe_provider"
    shift
  fi
fi

if [[ -n "$provider" ]]; then
  auth_token=$(get_ini_value "$provider" "ANTHROPIC_AUTH_TOKEN")
  [[ -z "${auth_token:-}" ]] && auth_token=$(get_ini_value "$provider" "API_KEY") # backward compat

  base_url=$(get_ini_value "$provider" "ANTHROPIC_BASE_URL")
  [[ -z "${base_url:-}" ]] && base_url=$(get_ini_value "$provider" "BASE_URL") # backward compat

  default_sonnet=$(get_ini_value "$provider" "ANTHROPIC_DEFAULT_SONNET_MODEL")
  default_haiku=$(get_ini_value "$provider" "ANTHROPIC_DEFAULT_HAIKU_MODEL")
  default_opus=$(get_ini_value "$provider" "ANTHROPIC_DEFAULT_OPUS_MODEL")

  legacy_model=$(get_ini_value "$provider" "ANTHROPIC_MODEL")
  [[ -z "${legacy_model:-}" ]] && legacy_model=$(get_ini_value "$provider" "MODEL")

  legacy_small_fast=$(get_ini_value "$provider" "ANTHROPIC_SMALL_FAST_MODE")
  [[ -z "${legacy_small_fast:-}" ]] && legacy_small_fast=$(get_ini_value "$provider" "SMALL_FAST_MODE")

  [[ -z "${default_sonnet:-}" ]] && default_sonnet="$legacy_model"
  [[ -z "${default_haiku:-}" ]] && default_haiku="$legacy_small_fast"
  [[ -z "${default_haiku:-}" ]] && default_haiku="$legacy_model"
  [[ -z "${default_opus:-}" ]] && default_opus="$legacy_model"

  missing=()
  [[ -z "${auth_token:-}" ]] && missing+=("ANTHROPIC_AUTH_TOKEN")
  [[ -z "${base_url:-}" ]] && missing+=("ANTHROPIC_BASE_URL")

  if (( ${#missing[@]} > 0 )); then
    printf "✖ Provider [%s] has incomplete config (missing: %s).\n" "$provider" "$(IFS=,; echo "${missing[*]}")" >&2
    exit 1
  fi

  export SETTINGS_PATH PROVIDER="$provider"
  export AUTH_TOKEN="$auth_token" BASE_URL="$base_url" DEFAULT_SONNET_MODEL="$default_sonnet" DEFAULT_HAIKU_MODEL="$default_haiku" DEFAULT_OPUS_MODEL="$default_opus"

  node <<'NODE'
const fs = require('fs');
const path = require('path');

const settingsPath = process.env.SETTINGS_PATH;
const claudeDir = path.dirname(settingsPath);
const envUpdates = {};
const maybeSet = (key, val) => {
  if (typeof val !== 'undefined' && val !== '') envUpdates[key] = val;
};
maybeSet('ANTHROPIC_AUTH_TOKEN', process.env.AUTH_TOKEN);
maybeSet('ANTHROPIC_BASE_URL', process.env.BASE_URL);
maybeSet('ANTHROPIC_DEFAULT_SONNET_MODEL', process.env.DEFAULT_SONNET_MODEL);
maybeSet('ANTHROPIC_DEFAULT_HAIKU_MODEL', process.env.DEFAULT_HAIKU_MODEL);
maybeSet('ANTHROPIC_DEFAULT_OPUS_MODEL', process.env.DEFAULT_OPUS_MODEL);

fs.mkdirSync(claudeDir, { recursive: true });

let data = {};
if (fs.existsSync(settingsPath)) {
  try {
    const raw = fs.readFileSync(settingsPath, 'utf8');
    data = raw.trim() ? JSON.parse(raw) : {};
  } catch (err) {
    console.error(`✖ Failed to parse ${settingsPath}: ${err.message}`);
    process.exit(1);
  }
}

data.env = { ...(data.env || {}), ...envUpdates };
if (!data.permissions) data.permissions = { allow: [], deny: [] };
if (typeof data.alwaysThinkingEnabled === 'undefined') data.alwaysThinkingEnabled = true;

fs.writeFileSync(settingsPath, JSON.stringify(data, null, 2));
console.error(`>>> Using provider: ${process.env.PROVIDER}`);
NODE
else
  # No provider — remove any previously injected provider env keys from settings.json
  if [[ -f "$SETTINGS_PATH" ]]; then
    SETTINGS_PATH="$SETTINGS_PATH" node <<'NODE'
const fs = require('fs');
const settingsPath = process.env.SETTINGS_PATH;
const keysToRemove = [
  'ANTHROPIC_AUTH_TOKEN',
  'ANTHROPIC_BASE_URL',
  'ANTHROPIC_DEFAULT_SONNET_MODEL',
  'ANTHROPIC_DEFAULT_HAIKU_MODEL',
  'ANTHROPIC_DEFAULT_OPUS_MODEL',
];
try {
  const raw = fs.readFileSync(settingsPath, 'utf8');
  const data = raw.trim() ? JSON.parse(raw) : {};
  if (data.env) {
    let changed = false;
    for (const k of keysToRemove) {
      if (k in data.env) { delete data.env[k]; changed = true; }
    }
    if (changed) {
      if (Object.keys(data.env).length === 0) delete data.env;
      fs.writeFileSync(settingsPath, JSON.stringify(data, null, 2));
    }
  }
} catch (_) {}
NODE
  fi
fi

# ---- locate official CLI (absolute paths to avoid recursion) ----
SELF_PATH="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

find_on_path() {
  local entry candidate
  local -a path_entries
  IFS=':' read -r -a path_entries <<< "${PATH:-}"
  for entry in "${path_entries[@]}"; do
    [ -z "$entry" ] && continue
    candidate="${entry%/}/claude"
    if [[ -x "$candidate" && "$candidate" != "$SELF_PATH" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

CANDIDATES=(
  "$HOME/.local/bin/claude"
  "$HOME/.claude/bin/claude"
  "/usr/local/bin/claude"
  "/usr/bin/claude"
  "/opt/homebrew/bin/claude"
)

if found="$(find_on_path)"; then
  CANDIDATES+=("$found")
fi

for p in "${CANDIDATES[@]}"; do
  if [[ -x "$p" ]]; then
    exec "$p" "$@"
  fi
done

echo "Official Claude CLI not found. Please install: curl -fsSL https://claude.ai/install.sh | bash" >&2
exit 1
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

[kimi]
ANTHROPIC_AUTH_TOKEN=sk-xxxxxxxxxxxxxxxx
ANTHROPIC_BASE_URL=https://api.kimi.com/coding/
ANTHROPIC_DEFAULT_SONNET_MODEL=kimi-for-coding
ANTHROPIC_DEFAULT_HAIKU_MODEL=kimi-for-coding
ANTHROPIC_DEFAULT_OPUS_MODEL=kimi-for-coding

[glm]
ANTHROPIC_AUTH_TOKEN=sk-xxxxxxxxxxxxxxxx
ANTHROPIC_BASE_URL=https://open.bigmodel.cn/api/anthropic/
ANTHROPIC_DEFAULT_SONNET_MODEL=glm-4.5
ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-4.5-air
ANTHROPIC_DEFAULT_OPUS_MODEL=glm-4.5
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
    msg "✅ Installation complete."
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
