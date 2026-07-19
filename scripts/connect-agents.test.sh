#!/usr/bin/env bash
# connect-agents.test.sh — unit test for connect-agents.sh (no DB, no root).
# Stubs sudo + issue-agent-token via a fake SB_HOME; exercises: placeholder →
# patched in BOTH agent.env and .mcp.json, real token → skipped, issuance
# failure → non-zero exit, missing lab → clean exit 0.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/connect-agents.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "✓ $*"; pass=$((pass+1)); }
bad() { echo "✗ $*"; fail=$((fail+1)); }

# ---- fake second_brain install ----------------------------------------------
SB="$TMP/opt"; mkdir -p "$SB/.venv/bin" "$SB/scripts" "$TMP/etc"
cat > "$SB/.venv/bin/python" <<'EOF'
#!/usr/bin/env bash
# fake venv python: emulate issue-agent-token.py — print a deterministic token
# derived from the --agent arg; fail for agent "broken".
args="$*"
agent=$(echo "$args" | sed -E 's/.*--agent ([^ ]+).*/\1/')
[ "$agent" = "broken" ] && { echo "boom" >&2; exit 1; }
echo "tok_${agent}_AbCdEf123456"
EOF
chmod +x "$SB/.venv/bin/python"
touch "$SB/scripts/issue-agent-token.py"
cat > "$TMP/etc/secrets.env" <<'EOF'
PG_HOST=/var/run/postgresql
PG_PORT=5432
PG_DATABASE=second_brain
PG_USER=second_brain
PG_PASSWORD=
EOF

# stub sudo: run the command as-is, dropping sudo's own flags/user args
mkdir -p "$TMP/bin"
cat > "$TMP/bin/sudo" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in -E) shift;; -u) shift 2;; *) break;; esac
done
exec "$@"
EOF
chmod +x "$TMP/bin/sudo"

# stub psql for token_valid(): echo "1" (token present) when FAKE_TOKEN_VALID=1,
# else empty (0 rows = stale/absent). exit 0 either way = query succeeded.
cat > "$TMP/bin/psql" <<'EOF'
#!/usr/bin/env bash
[ "${FAKE_TOKEN_VALID:-1}" = "1" ] && echo 1
exit 0
EOF
chmod +x "$TMP/bin/psql"
export PATH="$TMP/bin:$PATH"

mk_agent() {  # $1=name $2=bearer
  local ws="$TMP/lab/$1/.claude"; mkdir -p "$ws"
  cat > "$ws/agent.env" <<EOF
export AGENT_ID="$1"
export AGENT_BEARER="$2"
export AGENT_SCOPES="decisions,knowledge"
EOF
  cat > "$ws/.mcp.json" <<EOF
{"mcpServers":{"m":{"headers":{"Authorization":"Bearer $2"}},"r":{"headers":{"Authorization":"Bearer $2"}}}}
EOF
}

run_sut() {
  SB_HOME="$SB" SB_ETC="$TMP/etc" SECRETS="$TMP/etc/secrets.env" \
  SERVICE_USER="$(id -un)" AGENT_LAB_DIR="$TMP/lab" bash "$SUT" "$@"
}

# ---- case 1: placeholder agent gets patched in both files -------------------
mk_agent dev CHANGE_ME
out="$(run_sut 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "exit 0 on success" || bad "exit $rc: $out"
grep -q 'AGENT_BEARER="tok_dev_AbCdEf123456"' "$TMP/lab/dev/.claude/agent.env" \
  && ok "agent.env patched" || bad "agent.env not patched"
[ "$(grep -o 'Bearer tok_dev_AbCdEf123456' "$TMP/lab/dev/.claude/.mcp.json" | wc -l)" = 2 ] \
  && ok ".mcp.json patched in all places" || bad ".mcp.json not fully patched"
[ -f "$TMP/lab/dev/.claude/agent.env.bak-connect" ] && ok "backup created" || bad "no backup"
echo "$out" | grep -q 'tok_dev_AbCdEf123456' \
  && bad "raw token leaked to output" || ok "raw token not printed"
echo "$out" | grep -q 'scopes=decisions,knowledge' \
  && ok "scopes taken from agent.env" || bad "scopes not from agent.env"

# ---- case 2: idempotent — valid token in DB → skip --------------------------
out="$(FAKE_TOKEN_VALID=1 run_sut 2>&1)"
echo "$out" | grep -q 'dev: токен валиден в БД' \
  && ok "valid token in DB → skip" || bad "not idempotent on valid token: $out"

# ---- case 2b: stale token (not in DB, e.g. after reinstall) → reissue --------
out="$(FAKE_TOKEN_VALID=0 run_sut 2>&1)"
echo "$out" | grep -q 'dev: токена нет в БД' \
  && ok "stale token → reissue path" || bad "stale token not reissued: $out"
grep -q 'AGENT_BEARER="tok_dev_' "$TMP/lab/dev/.claude/agent.env" \
  && ok "stale token: agent.env re-patched" || bad "stale token: agent.env not patched"

# ---- case 3: issuance failure → exit 1, others still processed --------------
mk_agent broken CHANGE_ME
out="$(run_sut 2>&1)"; rc=$?
[ $rc -eq 1 ] && ok "exit 1 when issuance fails" || bad "expected exit 1, got $rc"
echo "$out" | grep -q 'broken: token issuance FAILED' \
  && ok "failure reported per-agent" || bad "failure not reported"

# ---- case 4: agent dir without agent.env is skipped -------------------------
mkdir -p "$TMP/lab/shared/.claude" 2>/dev/null; mkdir -p "$TMP/lab/plain"
out="$(run_sut 2>&1)"
echo "$out" | grep -q 'shared: no agent.env' && ok "non-wired dir skipped" || bad "non-wired dir not skipped"

# ---- case 5: no lab at all → clean exit 0 -----------------------------------
out="$(SB_HOME="$SB" SB_ETC="$TMP/etc" SECRETS="$TMP/etc/secrets.env" \
  SERVICE_USER="$(id -un)" AGENT_LAB_DIR="$TMP/nope" bash "$SUT" 2>&1)"; rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q 'nothing to connect' \
  && ok "missing lab → clean exit" || bad "missing lab handling broken (rc=$rc)"

echo
echo "passed=$pass failed=$fail"
[ $fail -eq 0 ]
