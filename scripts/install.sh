#!/usr/bin/env bash
# install.sh — second_brain bootstrap for a fresh Ubuntu 22.04 LTS VPS.
#
# Usage:
#   sudo bash scripts/install.sh
#
# Reads configuration from .env (or environment). Idempotent: re-running is safe.
# See README.md for the full deployment guide.

set -euo pipefail
set -o pipefail

# ---------------------------------------------------------------------------
# 0. Logging helpers
# ---------------------------------------------------------------------------

log()  { printf '[install %s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
die()  { printf '[install ERROR] %s\n' "$*" >&2; exit 1; }
note() { printf '\n=== %s ===\n' "$*"; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# 1. Platform check
# ---------------------------------------------------------------------------

note "1. Platform check"

if [ ! -r /etc/os-release ]; then
  die "cannot read /etc/os-release — this script supports Ubuntu 20.04+ LTS"
fi
# shellcheck disable=SC1091
. /etc/os-release
if [ "${ID:-}" != "ubuntu" ]; then
  die "unsupported platform: ID=${ID:-?} (need ubuntu)"
fi
MAJOR_VERSION="${VERSION_ID%.*}"
if [ "$MAJOR_VERSION" -lt 20 ]; then
  die "unsupported platform: VERSION_ID=${VERSION_ID:-?} (need ubuntu 20.04 LTS or newer)"
fi
log "platform ok: ubuntu ${VERSION_ID}"

if [ "$(id -u)" -ne 0 ]; then
  die "must run as root (sudo bash scripts/install.sh)"
fi

# ---------------------------------------------------------------------------
# 2. Load .env
# ---------------------------------------------------------------------------

note "2. Loading .env"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$REPO_ROOT/.env"
  set +a
  log ".env loaded"
else
  log ".env not present, falling back to environment + defaults"
fi

# Canonical env var names (single source of truth).
: "${INSTALL_DIR:=/opt/second_brain}"
: "${SERVICE_USER:=second_brain}"
: "${ETC_DIR:=/etc/second_brain}"
: "${LOG_DIR:=/var/log/second_brain}"
: "${STATE_DIR:=/var/lib/second_brain}"
: "${PG_HOST:=/var/run/postgresql}"
: "${PG_PORT:=5432}"
: "${PG_DATABASE:=second_brain}"
: "${PG_USER:=second_brain}"
: "${PG_PASSWORD:=}"
: "${MCP_MEMORY_PORT:=5001}"
: "${MCP_MEMORY_ROUTER_PORT:=5002}"
: "${MCP_AGENT_ROUTER_PORT:=5000}"
: "${VAULT_ROOT:=$INSTALL_DIR/vault}"

log "INSTALL_DIR=$INSTALL_DIR SERVICE_USER=$SERVICE_USER"
log "PG_DATABASE=$PG_DATABASE PG_USER=$PG_USER"

# Peer-auth coupling guard.
# A unix-socket PG_HOST (path starting with "/") combined with an empty
# PG_PASSWORD means Postgres *peer* authentication, where the OS user must
# match the database role. If SERVICE_USER != PG_USER under this config the
# services will fail to connect at runtime — fail fast here with guidance.
case "$PG_HOST" in
  /*)
    if [ -z "$PG_PASSWORD" ] && [ "$SERVICE_USER" != "$PG_USER" ]; then
      die "peer-auth misconfig: PG_HOST=$PG_HOST is a unix socket and PG_PASSWORD is empty (peer auth), but SERVICE_USER=$SERVICE_USER != PG_USER=$PG_USER. With Postgres peer auth the OS user MUST equal the DB role. Fix: set SERVICE_USER=PG_USER, or provide PG_PASSWORD (+ TCP PG_HOST) for password auth."
    fi
    log "peer-auth guard ok (unix socket PG_HOST=$PG_HOST, SERVICE_USER==PG_USER or password set)"
    ;;
  *)
    log "peer-auth guard skipped (TCP PG_HOST=$PG_HOST)"
    ;;
esac

# ---------------------------------------------------------------------------
# 3. apt packages (Postgres 16 + pgvector from apt.postgresql.org)
# ---------------------------------------------------------------------------

note "3. apt packages"

export DEBIAN_FRONTEND=noninteractive

apt-get update -y

# python3.11 from deadsnakes on 22.04
if ! command -v python3.11 >/dev/null 2>&1; then
  log "installing python3.11 (deadsnakes)"
  apt-get install -y software-properties-common
  add-apt-repository -y ppa:deadsnakes/ppa
  apt-get update -y
fi

# Postgres 16 from apt.postgresql.org (Ubuntu 22.04 universe only has 14).
# pgvector for PG 16 is in the same repo as postgresql-16-pgvector.
if [ ! -f /etc/apt/sources.list.d/pgdg.list ]; then
  log "adding apt.postgresql.org repo for Postgres 16"
  apt-get install -y curl ca-certificates gnupg lsb-release
  install -d /usr/share/keyrings
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] https://apt.postgresql.org/pub/repos/apt jammy-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list
  apt-get update -y
fi

apt-get install -y --no-install-recommends \
  python3.11 python3.11-venv python3.11-dev \
  postgresql-16 postgresql-16-pgvector \
  git curl jq ca-certificates gettext-base build-essential libpq-dev

log "apt install done"

# ---------------------------------------------------------------------------
# 4. Service user + directories
# ---------------------------------------------------------------------------

note "4. user + directories"

if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$INSTALL_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
  log "created system user $SERVICE_USER"
else
  log "user $SERVICE_USER already exists"
fi

mkdir -p \
  "$INSTALL_DIR" \
  "$INSTALL_DIR/services" \
  "$INSTALL_DIR/vault" \
  "$INSTALL_DIR/migrations" \
  "$INSTALL_DIR/secrets" \
  "$INSTALL_DIR/.cache" \
  "$ETC_DIR" \
  "$LOG_DIR" \
  "$STATE_DIR" \
  "$STATE_DIR/fastembed"

chmod 700 "$INSTALL_DIR/secrets" "$ETC_DIR"

# ---------------------------------------------------------------------------
# 5. Sync repo into install dir
# ---------------------------------------------------------------------------

note "5. sync repo → $INSTALL_DIR"

# Use rsync if available, else cp -a. Exclude development artifacts.
if command -v rsync >/dev/null 2>&1; then
  rsync -a \
    --delete \
    --exclude '.git' \
    --exclude '.venv' \
    --exclude '__pycache__' \
    --exclude '*.pyc' \
    --exclude '.env' \
    --exclude 'secrets/' \
    "$REPO_ROOT/" "$INSTALL_DIR/"
else
  cp -a "$REPO_ROOT/." "$INSTALL_DIR/"
fi

chown -R "$SERVICE_USER":"$SERVICE_USER" "$INSTALL_DIR" "$LOG_DIR" "$STATE_DIR"

# ---------------------------------------------------------------------------
# 5b. Seed vault from vault-template + verify scope dirs (anti-false-green)
# ---------------------------------------------------------------------------

note "5b. vault seed + verify"

VAULT_TEMPLATE_DIR="$INSTALL_DIR/vault-template"
if [ -d "$VAULT_TEMPLATE_DIR" ]; then
  # Seed the live vault from the template WITHOUT clobbering existing notes
  # (idempotent: --ignore-existing / cp -n). On re-install this only fills in
  # any scope dirs that were removed.
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --ignore-existing "$VAULT_TEMPLATE_DIR/" "$VAULT_ROOT/"
  else
    cp -an "$VAULT_TEMPLATE_DIR/." "$VAULT_ROOT/" 2>/dev/null || true
  fi
  chown -R "$SERVICE_USER":"$SERVICE_USER" "$VAULT_ROOT"
  log "seeded vault from vault-template → $VAULT_ROOT"
else
  log "WARNING: vault-template dir missing at $VAULT_TEMPLATE_DIR — vault not seeded"
fi

# Hard verify: a broken/empty sync (wrong VAULT_ROOT, failed copy) must turn
# the install red here rather than surface later as "scope not allowed" writes.
EXPECTED_SCOPES=(strategy decisions projects error-patterns inbox)
missing_scopes=()
for scope in "${EXPECTED_SCOPES[@]}"; do
  [ -d "$VAULT_ROOT/$scope" ] || missing_scopes+=("$scope")
done
if [ "${#missing_scopes[@]}" -ne 0 ]; then
  die "vault-sync verification FAILED: missing scope dirs under $VAULT_ROOT: ${missing_scopes[*]} — the vault-template copy did not land. Check $VAULT_TEMPLATE_DIR and VAULT_ROOT."
fi
log "vault-sync verified: expected scope dirs present under $VAULT_ROOT"

# ---------------------------------------------------------------------------
# 6. Python venv + deps
# ---------------------------------------------------------------------------

note "6. python venv"

if [ ! -x "$INSTALL_DIR/.venv/bin/python" ]; then
  sudo -u "$SERVICE_USER" python3.11 -m venv "$INSTALL_DIR/.venv"
  log "venv created"
else
  log "venv already exists"
fi

if [ -f "$INSTALL_DIR/requirements.txt" ]; then
  sudo -u "$SERVICE_USER" "$INSTALL_DIR/.venv/bin/pip" install --upgrade pip
  sudo -u "$SERVICE_USER" "$INSTALL_DIR/.venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt"
  log "pip install done"
else
  log "WARNING: $INSTALL_DIR/requirements.txt missing — skipping pip install"
fi

# ---------------------------------------------------------------------------
# 7. Postgres database + pgvector + password
# ---------------------------------------------------------------------------

note "7. postgres"

systemctl enable --now postgresql

# Create role if absent (idempotent)
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$PG_USER';" | grep -q 1; then
  sudo -u postgres createuser "$PG_USER"
  log "created postgres role $PG_USER"
else
  log "role $PG_USER exists"
fi

# Generate a password if one isn't already provided (idempotent across re-runs
# by persisting the value into $ETC_DIR/secrets.env on first install).
if [ -z "$PG_PASSWORD" ] && [ -f "$ETC_DIR/secrets.env" ]; then
  # Reuse the password from a previous install if present.
  EXISTING_PW="$(grep -E '^PG_PASSWORD=' "$ETC_DIR/secrets.env" | head -1 | cut -d= -f2- || true)"
  if [ -n "$EXISTING_PW" ]; then
    PG_PASSWORD="$EXISTING_PW"
    log "reusing PG_PASSWORD from $ETC_DIR/secrets.env"
  fi
fi
if [ -z "$PG_PASSWORD" ]; then
  PG_PASSWORD="$(openssl rand -hex 32)"
  log "generated new PG_PASSWORD (will be written to $ETC_DIR/secrets.env)"
fi

# Always (re)apply the password to the postgres role to keep them in sync.
sudo -u postgres psql -v ON_ERROR_STOP=1 \
  -c "ALTER USER $PG_USER WITH PASSWORD '$PG_PASSWORD';" >/dev/null
log "postgres role $PG_USER password set"

# Create DB if absent (idempotent)
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$PG_DATABASE';" | grep -q 1; then
  sudo -u postgres createdb -O "$PG_USER" "$PG_DATABASE"
  log "created database $PG_DATABASE"
else
  log "database $PG_DATABASE exists"
fi

sudo -u postgres psql -d "$PG_DATABASE" -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null
log "pgvector extension ready"

# ---------------------------------------------------------------------------
# 8. Write secrets.env BEFORE running migrations / issuing tokens
# ---------------------------------------------------------------------------

note "8. secrets.env"

# Single canonical EnvironmentFile consumed by all systemd units.
# Names MUST match what services/shared/config.py and the worker scripts read.
cat > "$ETC_DIR/secrets.env" <<EOF
# Generated by scripts/install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# Re-running install.sh preserves existing values where safe.
PG_HOST=$PG_HOST
PG_PORT=$PG_PORT
PG_DATABASE=$PG_DATABASE
PG_USER=$PG_USER
PG_PASSWORD=$PG_PASSWORD
VAULT_ROOT=$VAULT_ROOT
LOG_DIR=$LOG_DIR
STATE_DIR=$STATE_DIR
FASTEMBED_CACHE_DIR=$STATE_DIR/fastembed
EOF
chmod 600 "$ETC_DIR/secrets.env"
chown "$SERVICE_USER":"$SERVICE_USER" "$ETC_DIR/secrets.env"
log "wrote $ETC_DIR/secrets.env (review and add provider API keys as needed)"

# Also write a private install-time .env so the issue-token script and other
# manual CLI tools can read PG_PASSWORD without sudo.
INSTALL_ENV="$INSTALL_DIR/.env"
cat > "$INSTALL_ENV" <<EOF
PG_HOST=$PG_HOST
PG_PORT=$PG_PORT
PG_DATABASE=$PG_DATABASE
PG_USER=$PG_USER
PG_PASSWORD=$PG_PASSWORD
VAULT_ROOT=$VAULT_ROOT
MCP_MEMORY_PORT=$MCP_MEMORY_PORT
MCP_MEMORY_ROUTER_PORT=$MCP_MEMORY_ROUTER_PORT
MCP_AGENT_ROUTER_PORT=$MCP_AGENT_ROUTER_PORT
EOF
chmod 600 "$INSTALL_ENV"
chown "$SERVICE_USER":"$SERVICE_USER" "$INSTALL_ENV"

# ---------------------------------------------------------------------------
# 9. Run migrations
# ---------------------------------------------------------------------------

note "9. migrations"

if [ -d "$INSTALL_DIR/migrations" ] && [ -f "$INSTALL_DIR/scripts/migrate.sh" ]; then
  PG_DATABASE="$PG_DATABASE" bash "$INSTALL_DIR/scripts/migrate.sh"
else
  log "WARNING: migrations dir or migrate.sh missing — skipping"
fi

# ---------------------------------------------------------------------------
# 10. Generate admin agent token
# ---------------------------------------------------------------------------

note "10. admin token"

ADMIN_TOKEN_FILE="$INSTALL_DIR/secrets/admin.token"

if [ ! -s "$ADMIN_TOKEN_FILE" ]; then
  if [ -x "$INSTALL_DIR/.venv/bin/python" ] && [ -f "$INSTALL_DIR/scripts/issue-agent-token.py" ]; then
    # The redirect runs in this (root) shell; that's intentional since the
    # secrets dir is root-owned at this point. We chown to SERVICE_USER below.
    # shellcheck disable=SC2024
    PG_HOST="$PG_HOST" PG_PORT="$PG_PORT" \
    PG_DATABASE="$PG_DATABASE" PG_USER="$PG_USER" PG_PASSWORD="$PG_PASSWORD" \
      sudo -E -u "$SERVICE_USER" "$INSTALL_DIR/.venv/bin/python" \
      "$INSTALL_DIR/scripts/issue-agent-token.py" \
      --agent admin --scopes '*' \
      > "$ADMIN_TOKEN_FILE"
    chmod 600 "$ADMIN_TOKEN_FILE"
    chown "$SERVICE_USER":"$SERVICE_USER" "$ADMIN_TOKEN_FILE"
    if [ ! -s "$ADMIN_TOKEN_FILE" ]; then
      die "admin token generation produced an empty file ($ADMIN_TOKEN_FILE) — check above for errors"
    fi
    log "admin token written to $ADMIN_TOKEN_FILE"
  else
    die "cannot issue admin token (venv or script missing)"
  fi
else
  log "admin token already exists at $ADMIN_TOKEN_FILE"
fi

# ---------------------------------------------------------------------------
# 11. Pre-download FastEmbed model (avoids first-request OOM under hardening)
# ---------------------------------------------------------------------------

note "11. FastEmbed model pre-download + embedding probe"

FASTEMBED_MODEL="${FASTEMBED_MODEL:-intfloat/multilingual-e5-large}"
if [ -x "$INSTALL_DIR/.venv/bin/python" ]; then
  # Anti-false-green: a missing/broken embedding model silently degrades recall
  # to lexical-only and the rest of the install still looks green. Load the
  # model AND embed a probe string, asserting a non-empty vector, so a broken
  # embedding pipeline turns the install RED right here.
  # (We verify at the embedding layer rather than via a recall query in the
  # smoke test because the ingest-worker embeds asynchronously and may not have
  # caught up by the time the smoke test runs — a recall probe would be flaky.)
  if FASTEMBED_CACHE_DIR="$STATE_DIR/fastembed" \
       sudo -E -u "$SERVICE_USER" "$INSTALL_DIR/.venv/bin/python" - "$FASTEMBED_MODEL" "$STATE_DIR/fastembed" <<'PY'
import sys
from fastembed import TextEmbedding

model_name, cache_dir = sys.argv[1], sys.argv[2]
emb = TextEmbedding(model_name, cache_dir=cache_dir)
vecs = list(emb.embed(["query: smoke probe"]))
if not vecs or len(vecs[0]) == 0:
    raise SystemExit("embedding probe returned an empty vector")
print(f"fastembed model ready: {model_name} dim={len(vecs[0])}")
PY
  then
    log "fastembed model + embedding probe OK"
  elif [ "${SKIP_SMOKE_GATE:-0}" = "1" ]; then
    log "WARNING: fastembed pre-download/probe failed, но SKIP_SMOKE_GATE=1 — продолжаю (recall будет деградировать до lexical-only). Проверьте сеть/диск/$STATE_DIR/fastembed"
  else
    die "fastembed model pre-download/probe FAILED — embedding pipeline сломан, recall деградирует до lexical-only. Проверьте сеть/диск и $STATE_DIR/fastembed (SKIP_SMOKE_GATE=1 превратит это в предупреждение)"
  fi
else
  die "venv missing at $INSTALL_DIR/.venv — cannot verify the fastembed embedding pipeline (SKIP_SMOKE_GATE not honoured here: without a venv nothing can run)"
fi

# ---------------------------------------------------------------------------
# 12. Render + install systemd units
# ---------------------------------------------------------------------------

note "12. systemd units"

INSTALLED_UNITS=()
for tpl in "$INSTALL_DIR"/systemd/*.service.template; do
  [ -f "$tpl" ] || continue
  base="$(basename "$tpl" .service.template)"
  out="/etc/systemd/system/second_brain-${base}.service"
  sed \
    -e "s|{{INSTALL_DIR}}|$INSTALL_DIR|g" \
    -e "s|{{SERVICE_USER}}|$SERVICE_USER|g" \
    -e "s|{{ETC_DIR}}|$ETC_DIR|g" \
    -e "s|{{LOG_DIR}}|$LOG_DIR|g" \
    -e "s|{{STATE_DIR}}|$STATE_DIR|g" \
    "$tpl" > "$out"
  log "installed $out"
  INSTALLED_UNITS+=("second_brain-${base}")
done

systemctl daemon-reload

# ---------------------------------------------------------------------------
# 13. Start services (memory-mcp, memory_router-mcp, agent_router-mcp, agent_router-worker, ingest-worker)
# ---------------------------------------------------------------------------

note "13. start services"

systemctl enable --now \
  second_brain-memory-mcp \
  second_brain-memory_router-mcp \
  second_brain-agent_router-mcp \
  second_brain-agent_router-worker \
  second_brain-ingest-worker

sleep 3
systemctl --no-pager status \
  second_brain-memory-mcp \
  second_brain-memory_router-mcp \
  second_brain-agent_router-mcp \
  second_brain-agent_router-worker \
  second_brain-ingest-worker || true

# ---------------------------------------------------------------------------
# 14. Smoke test
# ---------------------------------------------------------------------------

note "14. smoke test"

if [ -x "$INSTALL_DIR/scripts/smoke-test.sh" ]; then
  if MCP_MEMORY_PORT="$MCP_MEMORY_PORT" MCP_MEMORY_ROUTER_PORT="$MCP_MEMORY_ROUTER_PORT" \
     MCP_AGENT_ROUTER_PORT="$MCP_AGENT_ROUTER_PORT" \
     bash "$INSTALL_DIR/scripts/smoke-test.sh"; then
    log "smoke test passed — install verified"
  elif [ "${SKIP_SMOKE_GATE:-0}" = "1" ]; then
    log "WARNING: smoke test failed, но SKIP_SMOKE_GATE=1 — продолжаю. Проверьте journalctl -u second_brain-*"
  else
    die "smoke test FAILED — установка НЕ подтверждена. Проверьте: journalctl -u second_brain-* (SKIP_SMOKE_GATE=1 превратит это в предупреждение)"
  fi
elif [ "${SKIP_SMOKE_GATE:-0}" = "1" ]; then
  log "WARNING: smoke test script missing, SKIP_SMOKE_GATE=1 — продолжаю без подтверждения"
else
  die "smoke test script missing — не могу подтвердить установку (SKIP_SMOKE_GATE=1 чтобы пропустить)"
fi

# ---------------------------------------------------------------------------
# 15. Done
# ---------------------------------------------------------------------------

note "15. done"

cat <<EOF

second_brain install complete.

Admin token (one-time print, also at $ADMIN_TOKEN_FILE mode 0600):

EOF

if [ -s "$ADMIN_TOKEN_FILE" ]; then
  cat "$ADMIN_TOKEN_FILE"
fi

cat <<EOF

Next steps:
  1. Verify services are listening:  ss -tlnp | grep -E '500[0-3]'
  2. Issue per-agent tokens:         $INSTALL_DIR/.venv/bin/python $INSTALL_DIR/scripts/issue-agent-token.py --agent <name> --scopes 'read,write'
  3. Point your local agents at:     http://<host>:$MCP_MEMORY_PORT/mcp (memory), :$MCP_MEMORY_ROUTER_PORT/mcp (memory_router), :$MCP_AGENT_ROUTER_PORT/mcp (agent_router)
  4. Set up the inbox-agent locally: bash $INSTALL_DIR/scripts/install-local.sh
  5. Review $ETC_DIR/secrets.env and add provider API keys you want available.

Logs:    journalctl -u second_brain-memory-mcp -f
Vault:   $VAULT_ROOT
Secrets: $INSTALL_DIR/secrets/ (mode 0600)

EOF
