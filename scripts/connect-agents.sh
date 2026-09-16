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
# И НЕ ТОЛЬКО токен: состав .mcp.json рендерится один раз, при создании агента,
# поэтому у агента прежнего выпуска в нём нет сервисов, добавленных позже (так
# у клиента 16.09.2026 не подключилась доска задач). Скрипт дописывает
# недостающие серверы и адреса в agent.env, сверяет права токена с базовым
# набором и ждёт готовности сервисов, прежде чем перезапускать сессию агента.
#
# Usage (root, after install.sh — install.sh calls it automatically):
#   bash scripts/connect-agents.sh
# Env:
#   AGENT_LAB_DIR   agent lab root (default: <operator home>/.claude-lab)
#   SB_HOME         second_brain install dir (default /opt/second_brain)
#   SB_ETC          config dir (default /etc/second_brain)
#   DEFAULT_SCOPES  scopes when agent.env has none (default below)
#   FORCE_REISSUE=1 reissue even if the agent already has a non-placeholder token
#   KEEP_AGENT_SCOPES=1  не доливать DEFAULT_SCOPES к тем, что уже в agent.env
#   SKIP_SERVICE_WAIT=1  не ждать готовности MCP-сервисов перед рестартом агента
#   SERVICE_WAIT_ATTEMPTS / SERVICE_WAIT_INTERVAL  окно ожидания (по умолчанию 60×2 с)
#
# Idempotent: у агента с валидным токеном и полной конфигурацией скрипт ничего
# не меняет и не перезапускает его (токен из БД не восстановить, поэтому без
# нужды не переиздаём); токен переиздаётся, только если его нет в БД, не хватает
# прав или задан FORCE_REISSUE=1.
# Tokens are NEVER printed; output shows a masked prefix only.
set -euo pipefail

SB_HOME="${SB_HOME:-/opt/second_brain}"
SB_ETC="${SB_ETC:-/etc/second_brain}"
SECRETS="${SECRETS:-$SB_ETC/secrets.env}"
VENV_PY="$SB_HOME/.venv/bin/python"
ISSUE_PY="$SB_HOME/scripts/issue-agent-token.py"
# task-board -- доска задач (task_mcp::TASKS_WRITE_SCOPE): без него агент видит
# задачу, но не может её взять и закрыть. error-patterns -- CLAUDE.md агента
# прямо велит писать «decisions/error-patterns to memory», а права не было.
# Оба доливались вручную после установки; здесь они и должны выдаваться.
DEFAULT_SCOPES="${DEFAULT_SCOPES:-decisions,external,knowledge,inbox,error-patterns,task-board}"
PLACEHOLDER="CHANGE_ME"

# Порты берём из конфигурации установленного second_brain ($SB_HOME/.env, его
# пишет install.sh) — иначе при нестандартных портах мы дописали бы агенту
# ссылки в пустоту. Дефолты совпадают с install.sh.
INSTALL_ENV="${INSTALL_ENV:-$SB_HOME/.env}"
env_file_val() {  # $1=file $2=key -> значение или пустая строка
  { grep -E "^$2=" "$1" 2>/dev/null || true; } | head -1 | sed -E "s/^$2=//" \
    | sed -e 's/^"//' -e 's/"$//'
}
port_of() {  # $1=key $2=default
  local v=""
  [ -f "$INSTALL_ENV" ] && v="$(env_file_val "$INSTALL_ENV" "$1")"
  case "$v" in ''|*[!0-9]*) printf '%s' "$2";; *) printf '%s' "$v";; esac
}
MCP_HOST="${MCP_HOST:-127.0.0.1}"
MCP_MEMORY_PORT="$(port_of MCP_MEMORY_PORT 5001)"
MCP_MEMORY_ROUTER_PORT="$(port_of MCP_MEMORY_ROUTER_PORT 5002)"
MCP_AGENT_ROUTER_PORT="$(port_of MCP_AGENT_ROUTER_PORT 5000)"
MCP_TASK_PORT="$(port_of MCP_TASK_PORT 5003)"

# Имя MCP-сервера в .mcp.json агента -> его URL. Единственный источник состава:
# агент, созданный до появления доски задач, этих серверов в своём .mcp.json не
# имеет, а раньше скрипт правил только Bearer — и второй сервис не подключался
# никогда (клиентский отчёт 16.09.2026).
SB_SERVERS="second_brain-memory=http://${MCP_HOST}:${MCP_MEMORY_PORT}/mcp
second_brain-memory_router=http://${MCP_HOST}:${MCP_MEMORY_ROUTER_PORT}/mcp
second_brain-agent_router=http://${MCP_HOST}:${MCP_AGENT_ROUTER_PORT}/mcp
second_brain-tasks=http://${MCP_HOST}:${MCP_TASK_PORT}/mcp"

# Переменные окружения агента (их читают хуки и поллер доски задач), которых у
# агентов прежних выпусков нет.
SB_ENV_URLS="SECOND_BRAIN_MEMORY_URL=http://${MCP_HOST}:${MCP_MEMORY_PORT}/mcp
SECOND_BRAIN_MEMORY_ROUTER_URL=http://${MCP_HOST}:${MCP_MEMORY_ROUTER_PORT}/mcp
SECOND_BRAIN_AGENT_ROUTER_URL=http://${MCP_HOST}:${MCP_AGENT_ROUTER_PORT}/mcp
SECOND_BRAIN_TASKS_URL=http://${MCP_HOST}:${MCP_TASK_PORT}/mcp"

# shellcheck source=lib/ui.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/ui.sh"

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
  note "no agent lab found ($AGENT_LAB_DIR) — nothing to connect (install agent-architecture first or set AGENT_LAB_DIR)"
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

# Без sudo -E: обычный sudo с ним оставляет HOME=/root, sudo-rs его игнорирует —
# одна и та же команда вела себя по-разному на 24.04 и 26.04. Скрипт выдачи
# токена сам читает $SB_HOME/.env (его пишет install.sh), так что PG_* ему через
# окружение не нужны.
issue_token() {  # $1=agent $2=scopes → raw token on stdout (never logged)
  sudo -u "$SERVICE_USER" "$VENV_PY" "$ISSUE_PY" --agent "$1" --scopes "$2"
}

# extract KEY value from an `export KEY="v"` / `KEY=v` style env file
# Нет ключа — пустая строка и код 0: grep без совпадения под set -e + pipefail
# молча обрывал весь скрипт на `scopes="$(env_val … AGENT_SCOPES)"`, и запасной
# DEFAULT_SCOPES для agent.env без scopes не срабатывал никогда.
env_val() {  # $1=file $2=key
  { grep -E "^(export +)?$2=" "$1" 2>/dev/null || true; } | head -1 \
    | sed -E "s/^(export +)?$2=//" | sed -e 's/^"//' -e 's/"$//'
}

# psql_scalar <sql> — одно значение из БД. rc=0 запрос прошёл, rc≠0 БД недоступна.
# Пароль — через временный pgpass-файл, а не PGPASSWORD: без sudo -E окружение до
# psql не доходит, а `env PGPASSWORD=…` положил бы пароль в argv. При peer-auth
# (сокет, пустой пароль) файл не нужен.
psql_scalar() {  # $1=sql
  local pgpass_env=() pgpass_file="" rc=0 out
  if [ -n "$PG_PASSWORD" ]; then
    pgpass_file="$(umask 077; mktemp)"
    printf '*:*:*:*:%s\n' "$(printf '%s' "$PG_PASSWORD" | sed -e 's/\\/\\\\/g' -e 's/:/\\:/g')" > "$pgpass_file"
    chown "$SERVICE_USER" "$pgpass_file" 2>/dev/null || true
    pgpass_env=(PGPASSFILE="$pgpass_file")
  fi
  out="$(sudo -u "$SERVICE_USER" env "${pgpass_env[@]}" psql \
           -h "${PG_HOST:-/var/run/postgresql}" -p "${PG_PORT:-5432}" \
           -d "$PG_DATABASE" -tAc "$1" 2>/dev/null)" || rc=$?
  [ -n "$pgpass_file" ] && rm -f "$pgpass_file"
  printf '%s' "$out"
  return "$rc"
}

# token_valid <raw-token> — существует ли токен в БД и не отозван.
# echo: 1 (валиден) / 0 (нет в БД или revoked) / '' (не смогли проверить БД).
# Токены хранятся как plain sha256(token) в agent_tokens.token_sha256
# (см. issue-agent-token.py / auth.py). Нужно на пере-установке second-brain:
# БД пересоздаётся, старые токены становятся невалидными.
token_valid() {  # $1=token
  local sha out rc=0
  sha="$(printf '%s' "$1" | sha256sum | awk '{print $1}')"
  out="$(psql_scalar "SELECT 1 FROM agent_tokens WHERE token_sha256='$sha' AND revoked_at IS NULL LIMIT 1")" || rc=$?
  if [ "$rc" -eq 0 ]; then
    [ "$(printf '%s' "$out" | tr -d '[:space:]')" = "1" ] && echo 1 || echo 0
  else
    echo ''   # psql недоступен / ошибка соединения — не знаем
  fi
}

# token_scopes <raw-token> — права, зашитые в токен, через запятую (пусто, если
# не смогли узнать). Права живут в БД, а не в agent.env: агент, заведённый до
# появления доски задач, держит валидный токен без scope task-board, и без этой
# сверки скрипт считал его «уже подключённым».
token_scopes() {  # $1=token
  local sha out rc=0
  sha="$(printf '%s' "$1" | sha256sum | awk '{print $1}')"
  out="$(psql_scalar "SELECT array_to_string(can_write_scopes, ',') FROM agent_tokens WHERE token_sha256='$sha' AND revoked_at IS NULL LIMIT 1")" || rc=$?
  [ "$rc" -eq 0 ] || { printf ''; return 0; }
  printf '%s' "$out" | tr -d '[:space:]'
}

# ---- готовность сервисов ----------------------------------------------------
# Зачем ждать: memory_router грузит модель эмбеддингов В СТАРТЕ (lifespan) и
# начинает слушать порт только после неё — на холодном кэше это минуты. Скрипт
# же перезапускает сессию агента сразу, и Claude Code, стартовав раньше сервиса,
# оставляет MCP-сервер в состоянии «не подключён» до следующего рестарта. Именно
# так у клиента 16.09.2026 не подключился recall.
#
# Пробуем initialize, а не tools/list: транспорт MCP сессионный, одиночный
# tools/list вернёт 400 «Missing session ID» при любом токене. initialize
# авторизации не требует (так задумано в MCP) и доказывает, что сервис жив.
# Открытую сессию сразу закрываем, чтобы она не висела до таймаута простоя.
mcp_ready() {  # $1=url
  local hdr body resp code sid
  hdr="$(mktemp)"
  body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"connect-agents","version":"1"}}}'
  resp="$(curl -sS --max-time 8 -D "$hdr" -w '\n__HTTP__:%{http_code}' \
    -X POST "$1" -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' -d "$body" 2>/dev/null || true)"
  code="${resp##*__HTTP__:}"
  if [ "$code" = "200" ] && printf '%s' "$resp" | grep -q '"serverInfo"'; then
    sid="$(tr -d '\r' < "$hdr" | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2; exit}')"
    [ -n "$sid" ] && curl -s --max-time 8 -o /dev/null -X DELETE "$1" \
      -H "Mcp-Session-Id: $sid" 2>/dev/null
    rm -f "$hdr"; return 0
  fi
  rm -f "$hdr"; return 1
}

SERVICES_READY=1
NOT_READY=""
wait_for_services() {
  local attempts="${SERVICE_WAIT_ATTEMPTS:-60}" interval="${SERVICE_WAIT_INTERVAL:-2}"
  local name url line a
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name="${line%%=*}"; url="${line#*=}"
    for a in $(seq 1 "$attempts"); do
      if mcp_ready "$url"; then break; fi
      if [ "$a" -eq "$attempts" ]; then
        NOT_READY="$NOT_READY $name"
        SERVICES_READY=0
      else
        sleep "$interval"
      fi
    done
  done <<SBSRV
$SB_SERVERS
SBSRV
  if [ "$SERVICES_READY" = "1" ]; then
    ok "MCP-сервисы отвечают: memory, memory_router (recall), agent_router, tasks (доска)"
  else
    warn "не отвечают:$NOT_READY — сессию агента НЕ перезапускаю, иначе она подключится мимо них"
    warn "почините сервис (systemctl status second_brain-*) и затем: systemctl restart claude-agent-<agent>.service"
  fi
}

if [ "${SKIP_SERVICE_WAIT:-0}" = "1" ]; then
  note "SKIP_SERVICE_WAIT=1 — готовность MCP-сервисов не проверяю"
else
  step "жду готовности MCP-сервисов (recall греет модель эмбеддингов — это может занять минуту)"
  wait_for_services
fi

# ---- .mcp.json: и токен, и состав серверов ----------------------------------
# Раньше здесь был один sed по «Bearer …»: он чинил токен, но не добавлял
# серверы, которых в файле нет. Файл рендерится один раз, при создании агента, и
# у агента прежнего выпуска в нём нет доски задач (её добавили позже) — сколько
# ни переустанавливай second_brain, второй сервис не подключится. Теперь состав
# приводится к текущему, а URL уже прописанных серверов не трогаем: оператор мог
# увести их на реверс-прокси.
SYNC_MCP_PY=$(cat <<'SYNCPY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
raw = sys.stdin.read().split("\n")
token = raw[0]
servers = {}
for line in raw[1:]:
    if "=" in line:
        name, url = line.split("=", 1)
        servers[name.strip()] = url.strip()

try:
    doc = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
except (OSError, ValueError) as exc:
    print(f"unreadable:{exc}")
    raise SystemExit(3)

if not isinstance(doc, dict):
    print("unreadable:not a JSON object")
    raise SystemExit(3)

mcp = doc.setdefault("mcpServers", {})
if not isinstance(mcp, dict):
    print("unreadable:mcpServers is not an object")
    raise SystemExit(3)

added, retoken = [], 0
for name, url in servers.items():
    entry = mcp.get(name)
    if not isinstance(entry, dict):
        mcp[name] = {
            "type": "http",
            "url": url,
            "headers": {"Authorization": f"Bearer {token}"},
        }
        added.append(name)
        continue
    headers = entry.setdefault("headers", {})
    if isinstance(headers, dict):
        headers["Authorization"] = f"Bearer {token}"
        retoken += 1

# Токен обновляем и у прочих серверов с Bearer, которые оператор завёл сам —
# прежний sed правил их все, и терять это поведение нельзя.
for name, entry in mcp.items():
    if name in servers or not isinstance(entry, dict):
        continue
    headers = entry.get("headers")
    if isinstance(headers, dict) and str(headers.get("Authorization", "")).startswith("Bearer "):
        headers["Authorization"] = f"Bearer {token}"
        retoken += 1

tmp = path.with_name(path.name + ".tmp-connect")
tmp.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
tmp.replace(path)
print(f"ok:{','.join(added) if added else '-'}:{retoken}")
SYNCPY
)

sync_mcp_json() {  # $1=файл, $2=токен (уходит питону через stdin, не в argv)
  # Код передаём через -c, а токен и состав серверов — через stdin: скрипт
  # на stdin («python -») занял бы тот же канал, и данные до него не дошли бы.
  printf '%s\n%s\n' "$2" "$SB_SERVERS" | "$VENV_PY" -c "$SYNC_MCP_PY" "$1"
}

# ---- agent.env: недостающие адреса сервисов ---------------------------------
# У агента прежнего выпуска нет SECOND_BRAIN_TASKS_URL — поллер доски задач не
# знает, куда ходить, даже когда сам сервис уже поднят.
ensure_env_urls() {  # $1=agent.env -> печатает имена дописанных переменных
  local line key added=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%%=*}"
    if ! grep -qE "^(export +)?$key=" "$1"; then
      printf 'export %s\n' "$line" >> "$1"
      added="$added $key"
    fi
  done <<SBENV
$SB_ENV_URLS
SBENV
  printf '%s' "$added"
}

# ---- scopes: прежние права плюс базовые -------------------------------------
# Права наследовались из agent.env как есть, поэтому агент, заведённый до
# появления доски задач, получал новый токен без scope task-board и не мог взять
# ни одной задачи. Объединяем с набором по умолчанию; KEEP_AGENT_SCOPES=1
# оставляет прежнее поведение.
merge_scopes() {  # $1=прежние scopes -> объединённый список через запятую
  if [ "${KEEP_AGENT_SCOPES:-0}" = "1" ] || [ -z "$1" ]; then
    printf '%s' "${1:-$DEFAULT_SCOPES}"
    return
  fi
  case ",$1," in
    *,\*,*) printf '%s' "$1"; return ;;   # wildcard уже шире любого списка
  esac
  printf '%s,%s' "$1" "$DEFAULT_SCOPES" | tr ',' '\n' | awk 'NF && !seen[$0]++' | paste -sd, -
}

connected=0; skipped=0; failed=0
for ws in "$AGENT_LAB_DIR"/*/.claude; do
  [ -d "$ws" ] || continue
  agent_env="$ws/agent.env"
  mcp_json="$ws/.mcp.json"
  agent="$(basename "$(dirname "$ws")")"
  [ -f "$agent_env" ] || { note "$agent: no agent.env — not a second_brain-wired agent, skipping"; continue; }

  current="$(env_val "$agent_env" AGENT_BEARER)"
  token=""            # непусто = выдали новый токен в этом проходе
  changed=0           # что-то в конфигурации агента реально поменялось
  need_token=1
  have_scopes=""      # права токена по БД; пусто = не знаем
  env_backed_up=0     # бэкап agent.env снимается один раз, перед первой правкой
  if [ -n "$current" ] && [ "$current" != "$PLACEHOLDER" ] && [ "${FORCE_REISSUE:-0}" != "1" ]; then
    # Не просто «есть непустой токен» — ПРОВЕРЯЕМ его в БД. При пере-установке
    # second-brain БД пересоздаётся и старые токены становятся невалидными;
    # проверка только на CHANGE_ME пропустила бы агента и оставила recall тихо
    # сломанным. Переиздаём ТОЛЬКО когда БД доказала, что токена нет/отозван;
    # если проверить не смогли — токен не трогаем (возможно, он рабочий), но
    # состав .mcp.json ниже приводим в порядок в любом случае.
    v="$(token_valid "$current")"
    if [ "$v" = "1" ]; then
      # Валидный токен — ещё не значит достаточный. Агент, заведённый до
      # появления доски задач, держит токен без scope task-board: сервис
      # поднят, сервер в .mcp.json есть, а взять задачу нечем. Права живут в
      # БД и меняются только перевыпуском, поэтому сверяем их здесь.
      have_scopes="$(token_scopes "$current")"
      want_scopes="$(merge_scopes "$have_scopes")"
      if [ -n "$have_scopes" ] && [ "$want_scopes" != "$have_scopes" ]; then
        step "$agent: токен валиден, но прав не хватает (нужно: $want_scopes) — переиздаю"
      else
        note "$agent: токен валиден в БД — оставляю (FORCE_REISSUE=1 чтобы переиздать)"
        need_token=0
      fi
    elif [ -z "$v" ]; then
      warn "$agent: токен есть, но проверка БД не удалась — токен оставляю как есть"
      warn "$agent: проверьте вручную: $SB_HOME/.venv/bin/python $SB_HOME/scripts/second_brain_doctor.py --mcp-json $mcp_json"
      need_token=0
    else
      step "$agent: токена нет в БД (устарел после пере-установки?) — переиздаю"
    fi
  fi

  owner="$(stat -c '%U:%G' "$agent_env")"

  # Бэкап — только когда файл действительно меняется, и свежий: раньше при
  # живом токене бэкап снимался лишь однажды, и следующие правки agent.env
  # (адреса, права) шли поверх файла, чей бэкап описывал состояние месячной
  # давности.
  backup_env() {  # $1 — готовая копия состояния до правки (необязательно)
    [ "$env_backed_up" = "1" ] && { [ -n "${1:-}" ] && rm -f "$1"; return 0; }
    if [ -n "${1:-}" ]; then mv "$1" "$agent_env.bak-connect"
    else cp -p "$agent_env" "$agent_env.bak-connect"; fi
    chown "$owner" "$agent_env.bak-connect"
    env_backed_up=1
  }
  set_env_scopes() {  # $1=scopes
    if grep -qE '^(export +)?AGENT_SCOPES=' "$agent_env"; then
      sed -i -E "s|^(export +)?AGENT_SCOPES=.*|export AGENT_SCOPES=\"$1\"|" "$agent_env"
    else
      printf 'export AGENT_SCOPES="%s"\n' "$1" >> "$agent_env"
    fi
  }

  if [ "$need_token" = "1" ]; then
    # База — права из БД, если их удалось прочитать: строка в agent.env могла
    # отстать от них, и перевыпуск по ней молча снял бы права, выданные вручную.
    scopes="$(merge_scopes "${have_scopes:-$(env_val "$agent_env" AGENT_SCOPES)}")"
    if ! token="$(issue_token "$agent" "$scopes")" || [ -z "$token" ]; then
      warn "$agent: token issuance FAILED — skipping"
      failed=$((failed+1)); continue
    fi

    # agent.env — hooks read AGENT_BEARER from the session environment
    backup_env
    sed -i -E "s|^(export +)?AGENT_BEARER=.*|export AGENT_BEARER=\"$token\"|" "$agent_env"
    grep -qE '^(export +)?AGENT_BEARER=' "$agent_env" \
      || printf 'export AGENT_BEARER="%s"\n' "$token" >> "$agent_env"
    # Права записываем туда же: следующий запуск (и хуки, которые их читают)
    # должны видеть тот же набор, что зашит в выданный токен.
    set_env_scopes "$scopes"
    chmod 600 "$agent_env"; chown "$owner" "$agent_env"
    changed=1
  else
    scopes="$(env_val "$agent_env" AGENT_SCOPES)"
    # Токен оставили, но строка AGENT_SCOPES могла разойтись с БД: права
    # выдавали перевыпуском мимо этого скрипта (так было у carmella —
    # task-board в БД есть, в agent.env нет). Истина — БД; строку сверяем.
    # Рестарт сессии ради этого не нужен: во время работы агента AGENT_SCOPES
    # никто не читает, это только база для следующего перевыпуска.
    if [ -n "$have_scopes" ] && [ "$have_scopes" != "$scopes" ]; then
      backup_env
      set_env_scopes "$have_scopes"
      chmod 600 "$agent_env"; chown "$owner" "$agent_env"
      ok "$agent: AGENT_SCOPES в agent.env сверен с БД: $have_scopes (было: ${scopes:-пусто})"
      scopes="$have_scopes"
    fi
  fi

  # Адреса сервисов в agent.env: у агента прежнего выпуска нет
  # SECOND_BRAIN_TASKS_URL, и поллер доски задач молчит даже при живом сервисе.
  env_before="$(mktemp "$agent_env.pre-connect.XXXXXX")"   # рядом, а не в /tmp: внутри токен
  cp -p "$agent_env" "$env_before"
  added_env="$(ensure_env_urls "$agent_env")"
  if [ -z "$added_env" ]; then
    rm -f "$env_before"
  else
    backup_env "$env_before"
    chmod 600 "$agent_env"; chown "$owner" "$agent_env"
    ok "$agent: в agent.env дописаны адреса:$added_env"
    changed=1
  fi

  # .mcp.json — отсюда MCP-инструменты агента берут и адреса сервисов, и токен.
  effective_token="${token:-$current}"
  if [ -f "$mcp_json" ] || [ -n "$effective_token" ]; then
    [ -f "$mcp_json" ] && cp -p "$mcp_json" "$mcp_json.bak-connect"
    if sync_out="$(sync_mcp_json "$mcp_json" "$effective_token")"; then
      sync_added="$(printf '%s' "$sync_out" | cut -d: -f2)"
      if [ -n "$sync_added" ] && [ "$sync_added" != "-" ]; then
        ok "$agent: в .mcp.json добавлены сервисы: $sync_added"
        changed=1
      fi
      chmod 600 "$mcp_json"; chown "$owner" "$mcp_json"
      [ -f "$mcp_json.bak-connect" ] && chown "$owner" "$mcp_json.bak-connect"
    else
      warn "$agent: .mcp.json не удалось разобрать (${sync_out#unreadable:}) — почините файл и запустите скрипт снова"
      failed=$((failed+1)); continue
    fi
  else
    warn "$agent: нет ни .mcp.json, ни токена — MCP-инструменты останутся без связи"
  fi

  if [ "$changed" = "0" ]; then
    note "$agent: уже подключён полностью — рестарт не нужен"
    skipped=$((skipped+1)); continue
  fi

  if [ -n "$token" ]; then
    ok "$agent: connected (scopes=$scopes, token=${token:0:6}…, backups: *.bak-connect)"
  else
    ok "$agent: конфигурация дополнена (scopes=$scopes, токен прежний, backups: *.bak-connect)"
  fi
  connected=$((connected+1))

  # Рестарт агента, чтобы он ПОДХВАТИЛ токен: живая сессия прочитала agent.env/
  # .mcp.json на старте (ещё с CHANGE_ME) — без рестарта recall не включится, и
  # оператору пришлось бы делать это вручную. Только если: юнит под systemd,
  # мы root (иначе systemctl не сработает) и не задан SKIP_AGENT_RESTART.
  unit="claude-agent-$agent.service"
  if [ "$SERVICES_READY" != "1" ]; then
    # Рестарт вслепую хуже отсутствия рестарта: сессия поднимется раньше
    # сервиса и запомнит его как неподключённый до следующего перезапуска.
    warn "$agent: сервисы ещё не отвечают — рестарт пропущен; после починки: systemctl restart $unit"
  elif [ "${SKIP_AGENT_RESTART:-0}" = "1" ]; then
    note "$agent: SKIP_AGENT_RESTART=1 — рестарт вручную: systemctl restart $unit"
  elif [ "$(id -u)" -ne 0 ]; then
    note "$agent: не root — рестарт вручную: sudo systemctl restart $unit"
  elif systemctl cat "$unit" >/dev/null 2>&1; then
    if systemctl restart "$unit" 2>/dev/null; then
      ok "$agent: перезапущен $unit — токен подхвачен, recall активен"
    else
      warn "$agent: не удалось перезапустить $unit — вручную: systemctl restart $unit"
    fi
  else
    note "$agent: нет systemd-юнита $unit — перезапустите сессию агента вручную, чтобы подхватить токен"
  fi
done

ok "done: $connected connected, $skipped already ok, $failed failed"
[ "$failed" -eq 0 ] || exit 1
