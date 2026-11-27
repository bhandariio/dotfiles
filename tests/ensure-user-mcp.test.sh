#!/usr/bin/env bash
# Idempotency and non-clobber checks for scripts/ensure-user-mcp.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/scripts/ensure-user-mcp.sh"
TMP=$(dotfiles_test_tmproot ensure-user-mcp)

run_script() {
  HOME=$1 JQ=${JQ:-jq} bash "$SCRIPT" || fail "ensure-user-mcp failed for $1"
}

checksum() {
  # shellcheck disable=SC2002
  cksum "$1" | awk '{print $1,$2}'
}

# --- creates both Claude servers, and a second run does not rewrite the file ---

home1=$TMP/fresh
mkdir -p "$home1"
run_script "$home1"
claude=$home1/.claude.json
assert_contains "$(cat "$claude")" '"linear-server"' "fresh claude config names linear-server"
assert_contains "$(cat "$claude")" 'https://mcp.linear.app/mcp' "fresh claude config points at Linear"
assert_contains "$(cat "$claude")" '"playwright"' "fresh claude config names playwright"
assert_contains "$(cat "$claude")" '@playwright/mcp@latest' "fresh claude config uses Playwright MCP"
mode=$(stat -c '%a' "$claude" 2>/dev/null || stat -f '%OLp' "$claude")
[ "$mode" = "600" ] || fail "fresh claude.json should be mode 600, got $mode"
before=$(checksum "$claude")
run_script "$home1"
after=$(checksum "$claude")
[ "$before" = "$after" ] || fail "second run rewrote a complete claude.json"
pass "claude create is idempotent"

# --- keeps login, history, and an existing customized server ---

home2=$TMP/existing
mkdir -p "$home2"
cat >"$home2/.claude.json" <<'EOF'
{
  "oauthAccount": { "emailAddress": "rahul@example.com" },
  "history": ["kept"],
  "projects": { "/Users/rahul/src/app": { "mcpServers": { "local-only": { "type": "stdio", "command": "true" } } } },
  "mcpServers": {
    "linear-server": { "type": "http", "url": "https://example.invalid/custom" }
  }
}
EOF
run_script "$home2"
merged=$(cat "$home2/.claude.json")
assert_contains "$merged" "rahul@example.com" "oauth account survives"
assert_contains "$merged" "kept" "history survives"
assert_contains "$merged" "local-only" "project-local MCP servers survive"
assert_contains "$merged" "https://example.invalid/custom" "existing linear-server URL is not replaced"
assert_contains "$merged" "@playwright/mcp@latest" "missing playwright server is added"
before=$(checksum "$home2/.claude.json")
run_script "$home2"
after=$(checksum "$home2/.claude.json")
[ "$before" = "$after" ] || fail "second run rewrote a merged claude.json"
pass "claude merge keeps login and history"

# --- invalid JSON and symlinks are left untouched ---

home3=$TMP/invalid
mkdir -p "$home3"
printf 'not json\n' >"$home3/.claude.json"
before=$(checksum "$home3/.claude.json")
run_script "$home3"
after=$(checksum "$home3/.claude.json")
[ "$before" = "$after" ] || fail "invalid claude.json was rewritten"
pass "invalid claude.json is left alone"

home4=$TMP/symlink
mkdir -p "$home4"
printf '{}\n' >"$home4/real.json"
ln -s real.json "$home4/.claude.json"
run_script "$home4"
[ -L "$home4/.claude.json" ] || fail "claude.json symlink was replaced"
grep -q playwright "$home4/real.json" && fail "symlink target was modified"
pass "claude.json symlink is left alone"

# --- Codex: create, preserve other settings, append only the missing table ---

home5=$TMP/codex-fresh
mkdir -p "$home5"
run_script "$home5"
codex=$home5/.codex/config.toml
assert_contains "$(cat "$codex")" '[mcp_servers.linear]' "fresh codex config has linear"
assert_contains "$(cat "$codex")" '[mcp_servers.playwright]' "fresh codex config has playwright"
assert_contains "$(cat "$codex")" 'https://mcp.linear.app/mcp' "fresh codex config points at Linear"
before=$(checksum "$codex")
run_script "$home5"
after=$(checksum "$codex")
[ "$before" = "$after" ] || fail "second run rewrote a complete codex config.toml"
pass "codex create is idempotent"

home6=$TMP/codex-existing
mkdir -p "$home6/.codex"
printf 'model = "gpt-5.4"\napproval_policy = "on-request"\n\n[mcp_servers.linear]\nurl = "https://example.invalid/custom"\n' >"$home6/.codex/config.toml"
run_script "$home6"
merged=$(cat "$home6/.codex/config.toml")
assert_contains "$merged" 'model = "gpt-5.4"' "codex model setting survives"
assert_contains "$merged" 'approval_policy = "on-request"' "codex approval policy survives"
assert_contains "$merged" 'https://example.invalid/custom' "existing linear table is not replaced"
assert_contains "$merged" '[mcp_servers.playwright]' "missing playwright table is appended"
count=$(grep -c '^\[mcp_servers\.linear\]' "$home6/.codex/config.toml")
[ "$count" = "1" ] || fail "linear table was duplicated"
run_script "$home6"
count=$(grep -c '^\[mcp_servers\.playwright\]' "$home6/.codex/config.toml")
[ "$count" = "1" ] || fail "playwright table was duplicated on the second run"
pass "codex append keeps existing settings"

# --- missing HOME fails ---

if env -u HOME bash "$SCRIPT" >/dev/null 2>&1; then
  fail "script succeeded without HOME"
fi
pass "missing HOME fails"
