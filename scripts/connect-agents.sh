#!/usr/bin/env bash
# connect-agents.sh — wire EXISTING agent workspaces to a freshly installed
# second_brain.
#
# WHY THIS EXISTS: the canonical install order is agent-architecture first,
# second_brain second. Agents scaffolded before second_brain exists carry the
# placeholder bearer `CHANGE_ME` in TWO places — `agent.env` (read by hooks via
# the environment) and `.mcp.json` (read by the agent's MCP tools). Fixing only
# one of them produces the worst failure mode: recall works on session start
# while every write to the shared brain silently 401s. This script fixes BOTH,
# atomically per agent, so a sequential install of the two repos needs no
# manual token plumbing.
#
# Usage (root, after install.sh — install.sh calls it automatically):
#   bash scripts/connect-agents.sh
# Env:
#   AGENT_LAB_DIR   agent lab root (default: <operator home>/.claude-lab)
#   SB_HOME         second_brain install dir (default /opt/second_brain)
#   SB_ETC          config dir (default /etc/second_brain)
#   DEFAULT_SCOPES  scopes when agent.env has none (default below)
#   FORCE_REISSUE=1 reissue even if the agent already has a non-placeholder token
#
# Idempotent: agents that already hold a real token are skipped (the token
# cannot be recovered from the DB, so reissuing without need would only churn).
# Tokens are NEVER printed; output shows a masked prefix only.
set -euo pipefail

SB_HOME="${SB_HOME:-/opt/second_brain}"
SB_ETC="${SB_ETC:-/etc/second_brain}"
SECRETS="${SECRETS:-$SB_ETC/secrets.env}"
VENV_PY="$SB_HOME/.venv/bin/python"
ISSUE_PY="$SB_HOME/scripts/issue-agent-token.py"
DEFAULT_SCOPES="${DEFAULT_SCOPES:-decisions,external,knowledge,inbox}"
PLACEHOLDER="CHANGE_ME"

log()  { printf '[connect-agents] %s\n' "$*"; }
warn() { printf '[connect-agents WARN] %s\n' "$*" >&2; }
die()  { printf '[connect-agents ERROR] %s\n' "$*" >&2; exit 1; }

# ---- locate the agent lab (operator's home, not root's) ----------------------
if [ -z "${AGENT_LAB_DIR:-}" ]; then
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    AGENT_LAB_DIR="$(getent passwd "$SUDO_USER" | cut -d: -f6)/.claude-lab"
  else
    AGENT_LAB_DIR="$HOME/.claude-lab"
  fi
  if [ ! -d "$AGENT_LAB_DIR" ]; then
    # last resort: a single .claude-lab somewhere under /home
    found="$(find /home -maxdepth 2 -name .claude-lab -type d 2>/dev/null | head -1)"
    [ -n "$found" ] && AGENT_LAB_DIR="$found"
  fi
fi
if [ ! -d "$AGENT_LAB_DIR" ]; then
  log "no agent lab found ($AGENT_LAB_DIR) — nothing to connect (install agent-architecture first or set AGENT_LAB_DIR)"
  exit 0
fi

[ -x "$VENV_PY" ] || die "venv missing: $VENV_PY (run install.sh first)"
[ -f "$ISSUE_PY" ] || die "issue-agent-token.py missing: $ISSUE_PY"

# ---- DB credentials: same no-source read as verify.sh ------------------------
read_key() {
  grep -E "^$1=" "$SECRETS" 2>/dev/null | head -1 | sed -e "s/^$1=//" -e 's/^"//' -e 's/"$//'
}
[ -r "$SECRETS" ] || die "cannot read $SECRETS (run as root)"
PG_HOST="$(read_key PG_HOST)"; PG_PORT="$(read_key PG_PORT)"
PG_DATABASE="$(read_key PG_DATABASE)"; PG_USER="$(read_key PG_USER)"
PG_PASSWORD="$(read_key PG_PASSWORD)"
SERVICE_USER="${SERVICE_USER:-$PG_USER}"

issue_token() {  # $1=agent $2=scopes → raw token on stdout (never logged)
  PG_HOST="$PG_HOST" PG_PORT="$PG_PORT" PG_DATABASE="$PG_DATABASE" \
  PG_USER="$PG_USER" PG_PASSWORD="$PG_PASSWORD" \
    sudo -E -u "$SERVICE_USER" "$VENV_PY" "$ISSUE_PY" --agent "$1" --scopes "$2"
}

# extract KEY value from an `export KEY="v"` / `KEY=v` style env file
env_val() {  # $1=file $2=key
  grep -E "^(export +)?$2=" "$1" 2>/dev/null | head -1 \
    | sed -E "s/^(export +)?$2=//" | sed -e 's/^"//' -e 's/"$//'
}

connected=0; skipped=0; failed=0
for ws in "$AGENT_LAB_DIR"/*/.claude; do
  [ -d "$ws" ] || continue
  agent_env="$ws/agent.env"
  mcp_json="$ws/.mcp.json"
  agent="$(basename "$(dirname "$ws")")"
  [ -f "$agent_env" ] || { log "$agent: no agent.env — not a second_brain-wired agent, skipping"; continue; }

  current="$(env_val "$agent_env" AGENT_BEARER)"
  if [ -n "$current" ] && [ "$current" != "$PLACEHOLDER" ] && [ "${FORCE_REISSUE:-0}" != "1" ]; then
    log "$agent: already has a real token — skipping (FORCE_REISSUE=1 to reissue)"
    skipped=$((skipped+1)); continue
  fi

  scopes="$(env_val "$agent_env" AGENT_SCOPES)"
  [ -n "$scopes" ] || scopes="$DEFAULT_SCOPES"

  if ! token="$(issue_token "$agent" "$scopes")" || [ -z "$token" ]; then
    warn "$agent: token issuance FAILED — skipping"
    failed=$((failed+1)); continue
  fi

  owner="$(stat -c '%U:%G' "$agent_env")"

  # agent.env — hooks read AGENT_BEARER from the session environment
  cp -p "$agent_env" "$agent_env.bak-connect"
  sed -i -E "s|^(export +)?AGENT_BEARER=.*|export AGENT_BEARER=\"$token\"|" "$agent_env"
  grep -qE '^(export +)?AGENT_BEARER=' "$agent_env" \
    || printf 'export AGENT_BEARER="%s"\n' "$token" >> "$agent_env"
  chmod 600 "$agent_env"; chown "$owner" "$agent_env" "$agent_env.bak-connect"

  # .mcp.json — the agent's MCP tools read the bearer from here; missing this
  # file is the silent-write-failure half of the bug this script exists for
  if [ -f "$mcp_json" ]; then
    cp -p "$mcp_json" "$mcp_json.bak-connect"
    sed -i -E "s|(\"Authorization\"[[:space:]]*:[[:space:]]*\")Bearer [^\"]*|\\1Bearer $token|g" "$mcp_json"
    chmod 600 "$mcp_json"; chown "$owner" "$mcp_json" "$mcp_json.bak-connect"
  else
    warn "$agent: .mcp.json missing — MCP tools will stay disconnected (agent.env updated)"
  fi

  log "$agent: connected (scopes=$scopes, token=${token:0:6}…, backups: *.bak-connect)"
  log "$agent: restart to pick up: systemctl restart claude-agent-$agent"
  connected=$((connected+1))
done

log "done: $connected connected, $skipped already ok, $failed failed"
[ "$failed" -eq 0 ] || exit 1
