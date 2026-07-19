#!/usr/bin/env bash
# smoke-test.sh — verify the three MCP services answer `tools/list` over HTTP.
#
# Usage:
#   bash scripts/smoke-test.sh                    # uses localhost ports
#   MCP_BASE=https://mcp.example.com bash ...     # uses domain (path routing behind your own reverse proxy)
#
# Reads admin token from $INSTALL_DIR/secrets/admin.token if present,
# else $ADMIN_TOKEN env var. Token is masked in all output.

set -euo pipefail

log()  { printf '[smoke %s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
fail() { printf '[smoke FAIL] %s\n' "$*" >&2; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$REPO_ROOT/.env"
  set +a
fi

: "${INSTALL_DIR:=/opt/second_brain}"
: "${MCP_BASE:=}"
: "${MCP_MEMORY_PORT:=5001}"
: "${MCP_MEMORY_ROUTER_PORT:=5002}"
: "${MCP_AGENT_ROUTER_PORT:=5000}"
: "${ADMIN_TOKEN:=}"

# Load admin token from file if not set
if [ -z "$ADMIN_TOKEN" ] && [ -r "$INSTALL_DIR/secrets/admin.token" ]; then
  ADMIN_TOKEN="$(tr -d '\n' < "$INSTALL_DIR/secrets/admin.token")"
fi

if [ -z "$ADMIN_TOKEN" ]; then
  log "no admin token available — running unauthenticated (expect 401 from services)"
  AUTH_HDR=()
else
  AUTH_HDR=(-H "Authorization: Bearer ${ADMIN_TOKEN}")
fi

# Build endpoint list: domain mode or localhost ports
if [ -n "$MCP_BASE" ]; then
  ENDPOINTS=(
    "memory:${MCP_BASE}/memory/mcp"
    "memory_router:${MCP_BASE}/memory_router/mcp"
    "agent_router:${MCP_BASE}/agent_router/mcp"
  )
else
  ENDPOINTS=(
    "memory:http://127.0.0.1:${MCP_MEMORY_PORT}/mcp"
    "memory_router:http://127.0.0.1:${MCP_MEMORY_ROUTER_PORT}/mcp"
    "agent_router:http://127.0.0.1:${MCP_AGENT_ROUTER_PORT}/mcp"
  )
fi

failures=0
for ep in "${ENDPOINTS[@]}"; do
  name="${ep%%:*}"
  url="${ep#*:}"

  # Probe with `initialize`, NOT `tools/list`: the MCP Streamable-HTTP transport
  # is session-based — a bare tools/list without a prior initialize handshake
  # returns http 400 "Missing session ID" regardless of the bearer, so it can
  # never pass as a one-shot curl. `initialize` is stateless, needs no session
  # and no auth (open by MCP design), returns serverInfo, and proves the service
  # is up and speaking MCP — the right liveness gate. Deep auth/tools coverage
  # lives in pytest (a real MCP client), not this smoke.
  body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}'

  # Poll, don't single-shot: MCP services (Python + FastMCP; memory_router also
  # warms embedding/rerank models) take 10-30s to bind their port after
  # `systemctl start`. install.sh only sleeps a few seconds before smoke, so a
  # single probe races a healthy-but-slow start and reports a false FAIL (all
  # three units were active/NRestarts=0, just not listening yet). Retry ~40s.
  attempts="${SMOKE_ATTEMPTS:-20}"; interval="${SMOKE_INTERVAL:-2}"
  ok_ep=0; http_code=""; masked_payload=""
  for _a in $(seq 1 "$attempts"); do
    resp=$(curl -sS \
      --max-time 8 \
      -w '\n__HTTP__:%{http_code}' \
      -X POST "$url" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json, text/event-stream" \
      "${AUTH_HDR[@]}" \
      -d "$body" 2>&1 || true)
    http_code="${resp##*__HTTP__:}"
    payload="${resp%__HTTP__:*}"
    # Mask any accidental token echo
    masked_payload="$(printf '%s' "$payload" | sed 's/Bearer [A-Za-z0-9_-]\{20,\}/Bearer ***/g')"
    # Success = HTTP 200 + serverInfo (service is up and speaks MCP).
    if [ "$http_code" = "200" ] && printf '%s' "$payload" | grep -q '"serverInfo"'; then
      ok_ep=1; break
    fi
    sleep "$interval"
  done

  if [ "$ok_ep" = "1" ]; then
    log "$name OK ($url)"
  else
    fail "$name $url — MCP не ответил serverInfo (http=$http_code) за ~$((attempts * interval))s"
    printf '  response: %s\n' "$(printf '%s' "$masked_payload" | head -c 200)"
    failures=$((failures + 1))
  fi
done

if [ "$failures" -eq 0 ]; then
  log "all 3 services healthy"
  exit 0
fi

fail "$failures service(s) failed"
exit 1
