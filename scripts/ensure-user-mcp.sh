#!/usr/bin/env bash
# Add user-scope Linear and Playwright MCP servers when they are missing.
#
# Claude Code stores user-scope servers in ~/.claude.json (top-level mcpServers),
# the same file it uses for login and history. Codex stores them in
# ~/.codex/config.toml, next to every other user setting. Neither file is safe
# to symlink or replace. This script inserts only the servers that are absent
# and leaves every existing entry, including a customized one, untouched.
#
# Equivalent to, without invoking the CLIs (they can prompt or rewrite the file):
#   claude mcp add --transport http --scope user linear-server https://mcp.linear.app/mcp
#   claude mcp add --scope user --transport stdio playwright -- npx -y @playwright/mcp@latest
#   codex mcp add linear --url https://mcp.linear.app/mcp
#   codex mcp add playwright -- npx -y @playwright/mcp@latest
#
# -y is included so npx does not stop to ask on a fresh machine.
# Names match Linear's Claude Code and Codex setup docs.
set -euo pipefail

: "${HOME:?HOME is required}"

JQ=${JQ:-jq}
CLAUDE_JSON=${CLAUDE_CONFIG_JSON:-$HOME/.claude.json}
CODEX_TOML=${CODEX_CONFIG_TOML:-$HOME/.codex/config.toml}

LINEAR_URL="https://mcp.linear.app/mcp"
PLAYWRIGHT_PACKAGE="@playwright/mcp@latest"

if ! command -v "$JQ" >/dev/null 2>&1; then
  echo "ensure-user-mcp: jq not found (set JQ=...)" >&2
  exit 1
fi

warn() {
  echo "ensure-user-mcp: $*" >&2
}

# Claude -----------------------------------------------------------------

# shellcheck disable=SC2016 # $linear and $playwright are jq variables, not shell
claude_filter='
  .mcpServers //= {}
  | if ((.mcpServers["linear-server"] | type) == "object") then .
    else .mcpServers["linear-server"] = { type: "http", url: $linear } end
  | if ((.mcpServers.playwright | type) == "object") then .
    else .mcpServers.playwright = {
      type: "stdio",
      command: "npx",
      args: ["-y", $playwright]
    } end
'

ensure_claude() {
  if [ -L "$CLAUDE_JSON" ]; then
    warn "$CLAUDE_JSON is a symlink; leaving it alone"
    return 0
  fi
  if [ -e "$CLAUDE_JSON" ] && [ ! -f "$CLAUDE_JSON" ]; then
    warn "$CLAUDE_JSON is not a regular file; leaving it alone"
    return 0
  fi
  if [ -f "$CLAUDE_JSON" ] && ! "$JQ" -e . "$CLAUDE_JSON" >/dev/null 2>&1; then
    warn "$CLAUDE_JSON is not valid JSON; leaving it alone"
    return 0
  fi

  if [ -f "$CLAUDE_JSON" ]; then
    local missing
    missing=$("$JQ" -r --arg linear "$LINEAR_URL" --arg playwright "$PLAYWRIGHT_PACKAGE" '
      def present(name): (.mcpServers[name] | type) == "object";
      if (present("linear-server") and present("playwright")) then "no" else "yes" end
    ' "$CLAUDE_JSON")
    if [ "$missing" = "no" ]; then
      return 0
    fi
  fi

  local dir tmp
  dir=$(dirname "$CLAUDE_JSON")
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.claude.json.tmp.XXXXXX")
  if [ -f "$CLAUDE_JSON" ]; then
    if ! "$JQ" --indent 2 --arg linear "$LINEAR_URL" --arg playwright "$PLAYWRIGHT_PACKAGE" \
      "$claude_filter" "$CLAUDE_JSON" >"$tmp"; then
      rm -f "$tmp"
      exit 1
    fi
  else
    if ! "$JQ" --indent 2 --arg linear "$LINEAR_URL" --arg playwright "$PLAYWRIGHT_PACKAGE" \
      "$claude_filter" >"$tmp" <<'EOF'
{}
EOF
    then
      rm -f "$tmp"
      exit 1
    fi
  fi
  chmod 600 "$tmp"
  mv "$tmp" "$CLAUDE_JSON"
}

# Codex ------------------------------------------------------------------

has_codex_table() {
  local name=$1
  [ -f "$CODEX_TOML" ] || return 1
  grep -Eq "^[[:space:]]*\\[mcp_servers\\.${name}\\][[:space:]]*(#.*)?$" "$CODEX_TOML"
}

append_codex_table() {
  local body="$1"
  local tmp last
  tmp=$(mktemp "$(dirname "$CODEX_TOML")/.config.toml.tmp.XXXXXX")
  if [ -f "$CODEX_TOML" ]; then
    cat "$CODEX_TOML" >"$tmp"
    if [ -s "$tmp" ]; then
      last=$(tail -c 1 "$tmp" | wc -l | tr -d ' ')
      if [ "$last" -eq 0 ]; then
        printf '\n' >>"$tmp"
      fi
    fi
    printf '\n' >>"$tmp"
  fi
  printf '%s\n' "$body" >>"$tmp"
  mv "$tmp" "$CODEX_TOML"
}

ensure_codex() {
  if [ -L "$CODEX_TOML" ]; then
    warn "$CODEX_TOML is a symlink; leaving it alone"
    return 0
  fi
  if [ -e "$CODEX_TOML" ] && [ ! -f "$CODEX_TOML" ]; then
    warn "$CODEX_TOML is not a regular file; leaving it alone"
    return 0
  fi

  local dir need_linear need_playwright
  dir=$(dirname "$CODEX_TOML")
  mkdir -p "$dir"

  if has_codex_table linear; then
    need_linear=0
  else
    need_linear=1
  fi
  if has_codex_table playwright; then
    need_playwright=0
  else
    need_playwright=1
  fi

  if [ "$need_linear" -eq 0 ] && [ "$need_playwright" -eq 0 ]; then
    return 0
  fi

  if [ ! -f "$CODEX_TOML" ]; then
    cat >"$CODEX_TOML" <<EOF
# MCP servers added by dotfiles scripts/ensure-user-mcp.sh.
# Rebuilds only append a server when its table is missing.

[mcp_servers.linear]
url = "${LINEAR_URL}"

[mcp_servers.playwright]
command = "npx"
args = ["-y", "${PLAYWRIGHT_PACKAGE}"]
EOF
    return 0
  fi

  if [ "$need_linear" -eq 1 ]; then
    append_codex_table "[mcp_servers.linear]
url = \"${LINEAR_URL}\""
  fi
  if [ "$need_playwright" -eq 1 ]; then
    append_codex_table "[mcp_servers.playwright]
command = \"npx\"
args = [\"-y\", \"${PLAYWRIGHT_PACKAGE}\"]"
  fi
}

ensure_claude
ensure_codex
