#!/usr/bin/env bash
# verify.sh — post-install / post-deploy health gate for second-brain.
#
# WHY THIS EXISTS (the lesson):
#   Unit tests answer "is the LOGIC correct?" and pass in CI even on a broken box.
#   This script answers "is THIS deployment correctly CONFIGURED and RUNNING?" —
#   the class of failure unit tests never see: wrong secrets, bad file perms,
#   missing pgvector, the peer-auth identity coupling, files renamed in code but
#   not on disk, a service that didn't bind its port. Run it as the LAST step of
#   install.sh; a FAIL must stop the install. It is read-only and idempotent, so
#   the same script doubles as an on-demand health check and a pre-prod canary.
#
# AGENT COUNT IS THE LEARNER'S CHOICE: nothing here hardcodes agent names or a
#   count. Agent presence is discovered from the agent_tokens table — works with
#   one agent or many; zero agents is a WARN (deploy one), not a FAIL.
#
# EXIT: 0 = healthy (warnings allowed) · 1 = at least one FAIL (block the deploy).
# RUN AS: root (or the service user). Reading secrets + peer-auth psql need that.
#
# Usage: verify.sh [--full]
#   --full   also run the pytest suite (heavier; off by default for a fast gate).
set -uo pipefail

# ---- config (override via env; defaults match the standard install topology) ----
SB_HOME="${SB_HOME:-/opt/second_brain}"
SB_ETC="${SB_ETC:-/etc/second_brain}"
SECRETS="${SECRETS:-$SB_ETC/secrets.env}"
VENV_PY="${VENV_PY:-$SB_HOME/.venv/bin/python}"
# optional: set to a real agent token to additionally run an authenticated MCP
# probe (tokens are stored hashed, so verify cannot mint one itself).
VERIFY_BEARER="${VERIFY_BEARER:-}"

# MCP endpoints to probe: "unit:port:path". Standard consolidated topology
# (memory/agent_router/task live in one core process, memory_router is separate). Edit the
# ports here only if you changed them at install time.
MCP_ENDPOINTS=(
  "second_brain-core-mcp:8767:/mcp"    # memory
  "second_brain-core-mcp:8766:/mcp"    # agent_router
  "second_brain-core-mcp:8769:/mcp"    # task
  "second_brain-memory_router-mcp:8768:/mcp"  # memory_router
)
WORKER_UNITS=( second_brain-ingest-worker second_brain-agent_router-worker )
REQUIRED_SECRET_KEYS=( PG_HOST PG_PORT PG_DATABASE PG_USER PG_PASSWORD \
                       VAULT_ROOT LOG_DIR STATE_DIR FASTEMBED_CACHE_DIR )
REQUIRED_TABLES=( agent_tokens agents chunks documents delivery_outbox \
                  embedding_jobs schema_migrations tasks )

FULL=0; [ "${1:-}" = "--full" ] && FULL=1

# ---- output framework ----
PASS=0; WARN=0; FAILN=0
if [ -t 1 ]; then g=$'\e[32m'; y=$'\e[33m'; r=$'\e[31m'; d=$'\e[2m'; x=$'\e[0m'
else g=; y=; r=; d=; x=; fi
pass(){ PASS=$((PASS+1));  printf '  %sPASS%s %s\n' "$g" "$x" "$1"; }
warn(){ WARN=$((WARN+1));  printf '  %sWARN%s %s\n' "$y" "$x" "$1"; }
fail(){ FAILN=$((FAILN+1)); printf '  %sFAIL%s %s\n' "$r" "$x" "$1"; }
sec(){  printf '\n%s== %s ==%s\n' "$d" "$1" "$x"; }

# ---- read a KEY=value from secrets WITHOUT sourcing (never execute the file) ----
read_key(){
  local line
  if [ -r "$SECRETS" ]; then line=$(grep -E "^$1=" "$SECRETS" 2>/dev/null | head -1)
  else line=$(sudo grep -E "^$1=" "$SECRETS" 2>/dev/null | head -1); fi
  printf '%s' "${line#*=}" | sed -e 's/^"//' -e 's/"$//'
}

# ================================================================= secrets ====
sec "Secrets & config"
if [ -r "$SECRETS" ] || sudo test -r "$SECRETS" 2>/dev/null; then
  pass "secrets file present & readable: $SECRETS"
  for k in "${REQUIRED_SECRET_KEYS[@]}"; do
    [ -n "$(read_key "$k")" ] && pass "secret set: $k" || fail "secret missing/empty: $k"
  done
else
  fail "cannot read $SECRETS (run as root or the service user)"
fi

SB_USER="$(read_key PG_USER)"; SB_DB="$(read_key PG_DATABASE)"

# run psql exercising the SAME peer-auth path the services use (OS user == role)
psql_as(){
  if [ "$(id -un)" = "$SB_USER" ]; then psql -d "$SB_DB" "$@"
  else sudo -u "$SB_USER" psql -d "$SB_DB" "$@"; fi
}

# ====================================================== identity / peer auth ==
# The single biggest deploy footgun: pg_hba 'local peer' couples
# OS-user == pg-role == PG_USER. Connecting as PG_USER over the socket and
# reading back current_user proves all three line up at once.
sec "Database identity (peer-auth coupling)"
if [ -z "$SB_USER" ]; then
  fail "PG_USER empty — cannot check identity"
elif ! id "$SB_USER" >/dev/null 2>&1; then
  fail "OS user '$SB_USER' does not exist (services run as this user)"
else
  cu="$(psql_as -tAc 'SELECT current_user' 2>/dev/null | tr -d '[:space:]')"
  cd="$(psql_as -tAc 'SELECT current_database()' 2>/dev/null | tr -d '[:space:]')"
  [ "$cu" = "$SB_USER" ] && pass "peer auth OK: OS user, pg role & PG_USER all = '$SB_USER'" \
                         || fail "peer-auth mismatch: connected as '${cu:-<none>}', expected '$SB_USER'"
  [ "$cd" = "$SB_DB" ] && pass "connected to expected DB: '$SB_DB'" \
                       || fail "wrong DB: got '${cd:-<none>}', expected '$SB_DB'"
fi

# ============================================================ pgvector/schema ==
sec "Postgres extension & schema"
ext="$(psql_as -tAc "SELECT extname FROM pg_extension WHERE extname='vector'" 2>/dev/null | tr -d '[:space:]')"
[ "$ext" = "vector" ] && pass "pgvector extension installed" || fail "pgvector extension MISSING"
for t in "${REQUIRED_TABLES[@]}"; do
  reg="$(psql_as -tAc "SELECT to_regclass('public.$t')" 2>/dev/null | tr -d '[:space:]')"
  [ "$reg" = "$t" ] && pass "table present: $t" || fail "table MISSING: $t (run migrations?)"
done

# ================================================================ filesystem ==
sec "Filesystem & permissions"
for dvar in VAULT_ROOT LOG_DIR STATE_DIR FASTEMBED_CACHE_DIR; do
  dir="$(read_key "$dvar")"; [ -z "$dir" ] && { warn "$dvar unset — skipped"; continue; }
  if sudo -u "$SB_USER" test -d "$dir" 2>/dev/null; then
    sudo -u "$SB_USER" test -w "$dir" 2>/dev/null \
      && pass "$dvar exists & writable by $SB_USER: $dir" \
      || fail "$dvar exists but NOT writable by $SB_USER: $dir"
  else
    fail "$dvar directory missing: $dir"
  fi
done

# ===================================================== python venv & imports ==
# Catches the "renamed in code but not on disk" class (e.g. a module import that
# points at a file that no longer exists) — a pure import smoke, no DB needed.
sec "Python venv & import smoke"
if sudo -u "$SB_USER" test -x "$VENV_PY" 2>/dev/null; then
  pass "venv interpreter present: $VENV_PY"
  if (cd "$SB_HOME" && sudo -u "$SB_USER" "$VENV_PY" - <<'PY' 2>/dev/null); then
import importlib
for m in ("services.shared.config", "scripts.second_brain_doctor"):
    importlib.import_module(m)
PY
    pass "core modules import cleanly"
  else
    fail "import smoke FAILED (stale module path / broken rename?) — run: cd $SB_HOME && $VENV_PY -c 'import scripts.second_brain_doctor'"
  fi
else
  fail "venv interpreter missing/not executable: $VENV_PY"
fi

# ================================================== services + MCP endpoints ==
sec "Services & MCP endpoints"
# unit liveness (dedup the unit list)
declare -A seen=()
for spec in "${MCP_ENDPOINTS[@]}" "${WORKER_UNITS[@]/%/::}"; do
  unit="${spec%%:*}"; [ -n "${seen[$unit]:-}" ] && continue; seen[$unit]=1
  [ "$(systemctl is-active "$unit.service" 2>/dev/null)" = "active" ] \
    && pass "service active: $unit" || fail "service NOT active: $unit"
done
# port listening + speaks MCP (initialize returns serverInfo). Auth is enforced
# at tool-call level (initialize is open by MCP design), so this checks liveness,
# not authorization — see the agents section / VERIFY_BEARER below.
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"verify","version":"1"}}}'
for spec in "${MCP_ENDPOINTS[@]}"; do
  IFS=: read -r unit port path <<<"$spec"
  if ! ss -ltn 2>/dev/null | grep -q ":$port "; then
    fail "port $port not listening ($unit)"; continue
  fi
  body="$(curl -s --max-time 8 -X POST "http://127.0.0.1:$port$path" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d "$init" 2>/dev/null)"
  echo "$body" | grep -q '"serverInfo"' \
    && pass "MCP up on :$port ($unit)" \
    || fail "MCP on :$port did not return serverInfo ($unit)"
done

# ==================================================== agents (count-agnostic) ==
sec "Registered agents"
n="$(psql_as -tAc 'SELECT count(*) FROM agent_tokens WHERE revoked_at IS NULL' 2>/dev/null | tr -d '[:space:]')"
case "$n" in
  ''|*[!0-9]*) fail "could not query agent_tokens" ;;
  0) warn "no agents registered yet — deploy at least one and create its token" ;;
  *) pass "$n active agent token(s) registered" ;;
esac
# Optional positive auth probe: set VERIFY_BEARER=<an agent's token> to confirm an
# authenticated tool call succeeds end-to-end (tokens are stored hashed, so verify
# cannot mint one itself).
if [ -n "$VERIFY_BEARER" ]; then
  IFS=: read -r _ port path <<<"${MCP_ENDPOINTS[0]}"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -X POST "http://127.0.0.1:$port$path" \
    -H "Authorization: Bearer $VERIFY_BEARER" -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' -d "$init" 2>/dev/null)"
  [ "$code" = "200" ] && pass "authenticated MCP probe OK (:$port)" \
                      || fail "authenticated MCP probe got HTTP $code (:$port)"
fi

# ===================================================== env drift & full tests ==
sec "Config drift & tests"
if sudo -u "$SB_USER" test -f "$SB_HOME/scripts/check_env_sync.py" 2>/dev/null; then
  (cd "$SB_HOME" && sudo -u "$SB_USER" "$VENV_PY" scripts/check_env_sync.py >/dev/null 2>&1) \
    && pass "env in sync with .env.example (no undocumented vars)" \
    || warn "env drift: code uses vars absent from .env.example (run scripts/check_env_sync.py)"
else
  warn "check_env_sync.py not found — skipped"
fi
if [ "$FULL" = 1 ]; then
  (cd "$SB_HOME" && sudo -u "$SB_USER" "$VENV_PY" -m pytest -q >/dev/null 2>&1) \
    && pass "full pytest suite green" || fail "pytest suite has failures (run: $VENV_PY -m pytest)"
else
  printf '  %s(skip)%s full pytest suite — pass --full to include it\n' "$d" "$x"
fi

# ===================================================================== summary ==
printf '\n%s---------------------------------------------%s\n' "$d" "$x"
printf '  %sPASS %d%s   %sWARN %d%s   %sFAIL %d%s\n' "$g" "$PASS" "$x" "$y" "$WARN" "$x" "$r" "$FAILN" "$x"
if [ "$FAILN" -gt 0 ]; then
  printf '  %sDEPLOY GATE: FAILED%s — fix the FAILs above before proceeding.\n' "$r" "$x"; exit 1
fi
printf '  %sDEPLOY GATE: PASSED%s%s\n' "$g" "$x" "$( [ "$WARN" -gt 0 ] && printf ' (with warnings)')"
exit 0
