#!/usr/bin/env bash
# connect-agents.test.sh — unit test for connect-agents.sh (no DB, no root).
# Stubs sudo, psql, curl, systemctl and issue-agent-token via a fake SB_HOME.
# Exercises: placeholder → patched in BOTH agent.env and .mcp.json, missing
# servers added to .mcp.json, missing URLs added to agent.env, narrow scopes
# widened, real token + full config → nothing to do, services down → no agent
# restart, issuance failure → non-zero exit, missing lab → clean exit 0.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/connect-agents.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "✓ $*"; pass=$((pass+1)); }
bad() { echo "✗ $*"; fail=$((fail+1)); }

FULL_SCOPES="decisions,external,knowledge,inbox,error-patterns,task-board"

# ---- fake second_brain install ----------------------------------------------
SB="$TMP/opt"; mkdir -p "$SB/.venv/bin" "$SB/scripts" "$TMP/etc"
cat > "$SB/.venv/bin/python" <<'EOF'
#!/usr/bin/env bash
# fake venv python. Два режима:
#   * с --agent  — эмулирует issue-agent-token.py (детерминированный токен);
#   * иначе      — настоящий python3: так тестируется реальная синхронизация
#     .mcp.json, а не её пересказ.
case "$*" in
  *--agent*)
    agent=$(echo "$*" | sed -E 's/.*--agent ([^ ]+).*/\1/')
    [ "$agent" = "broken" ] && { echo "boom" >&2; exit 1; }
    echo "tok_${agent}_AbCdEf123456"
    ;;
  *) exec python3 "$@" ;;
esac
EOF
chmod +x "$SB/.venv/bin/python"
touch "$SB/scripts/issue-agent-token.py"
# Порт доски задач нарочно нестандартный: скрипт обязан взять его из .env
# установленного second_brain, а не из собственного дефолта.
cat > "$SB/.env" <<'EOF'
MCP_MEMORY_PORT=5001
MCP_MEMORY_ROUTER_PORT=5002
MCP_AGENT_ROUTER_PORT=5000
MCP_TASK_PORT=5999
EOF
cat > "$TMP/etc/secrets.env" <<'EOF'
PG_HOST=/var/run/postgresql
PG_PORT=5432
PG_DATABASE=second_brain
PG_USER=second_brain
PG_PASSWORD=
EOF

mkdir -p "$TMP/bin"
# stub sudo: run the command as-is, dropping sudo's own flags/user args
cat > "$TMP/bin/sudo" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in -E) shift;; -u) shift 2;; *) break;; esac
done
exec "$@"
EOF
chmod +x "$TMP/bin/sudo"

# stub psql: token_valid → FAKE_TOKEN_VALID, token_scopes → FAKE_TOKEN_SCOPES.
cat > "$TMP/bin/psql" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *can_write_scopes*) echo "${FAKE_TOKEN_SCOPES:-decisions,external,knowledge,inbox,error-patterns,task-board}";;
  *) [ "${FAKE_TOKEN_VALID:-1}" = "1" ] && echo 1;;
esac
exit 0
EOF
chmod +x "$TMP/bin/psql"

# stub curl: отвечает на initialize как живой MCP-сервис, пока FAKE_SERVICES_UP=1.
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
hdr=""; out=""; prev=""
for a in "$@"; do
  [ "$prev" = "-D" ] && hdr="$a"
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
# DELETE-закрытие сессии идёт с -o /dev/null: молчим, как настоящий curl.
[ -n "$out" ] && exit 0
if [ "${FAKE_SERVICES_UP:-1}" != "1" ]; then
  printf '\n__HTTP__:000'
  exit 0
fi
[ -n "$hdr" ] && printf 'HTTP/1.1 200 OK\r\nMcp-Session-Id: sess-1\r\n\r\n' > "$hdr"
printf '{"result":{"serverInfo":{"name":"fake"}}}\n__HTTP__:200'
EOF
chmod +x "$TMP/bin/curl"

# stub systemctl: пишет вызовы в журнал, чтобы тест видел, был ли рестарт.
cat > "$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${SYSTEMCTL_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$TMP/bin/systemctl"

# stub id: скрипт рестартует юнит только от root, а тест идёт под обычным
# пользователем — подменяем только `id -u`, остальное отдаём настоящему id.
cat > "$TMP/bin/id" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-u" ] && [ "${FAKE_ROOT:-1}" = "1" ]; then echo 0; exit 0; fi
exec /usr/bin/id "$@"
EOF
chmod +x "$TMP/bin/id"
export PATH="$TMP/bin:$PATH"

mk_agent() {  # $1=name $2=bearer [$3=scopes]
  local ws="$TMP/lab/$1/.claude"; mkdir -p "$ws"
  cat > "$ws/agent.env" <<EOF
export AGENT_ID="$1"
export AGENT_BEARER="$2"
export AGENT_SCOPES="${3:-decisions,knowledge}"
EOF
  cat > "$ws/.mcp.json" <<EOF
{"mcpServers":{"m":{"headers":{"Authorization":"Bearer $2"}},"r":{"headers":{"Authorization":"Bearer $2"}}}}
EOF
}

run_sut() {
  SYSTEMCTL_LOG="${SYSTEMCTL_LOG:-$TMP/systemctl.log}" \
  SB_HOME="$SB" SB_ETC="$TMP/etc" SECRETS="$TMP/etc/secrets.env" \
  SERVICE_WAIT_ATTEMPTS=1 SERVICE_WAIT_INTERVAL=0 \
  SERVICE_USER="$(id -un)" AGENT_LAB_DIR="$TMP/lab" bash "$SUT" "$@"
}

json_has() {  # $1=file $2=server -> печатает url или пусто
  python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(d.get('mcpServers',{}).get(sys.argv[2],{}).get('url',''))
" "$1" "$2" 2>/dev/null
}

# ---- case 1: placeholder agent gets patched in both files -------------------
mk_agent dev CHANGE_ME
out="$(run_sut 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "exit 0 on success" || bad "exit $rc: $out"
grep -q 'AGENT_BEARER="tok_dev_AbCdEf123456"' "$TMP/lab/dev/.claude/agent.env" \
  && ok "agent.env patched" || bad "agent.env not patched"
# 2 «чужих» сервера оператора + 4 наших
[ "$(grep -o 'Bearer tok_dev_AbCdEf123456' "$TMP/lab/dev/.claude/.mcp.json" | wc -l)" = 6 ] \
  && ok ".mcp.json: токен проставлен во все серверы" || bad ".mcp.json not fully patched"
[ -f "$TMP/lab/dev/.claude/agent.env.bak-connect" ] && ok "backup created" || bad "no backup"
echo "$out" | grep -q 'tok_dev_AbCdEf123456' \
  && bad "raw token leaked to output" || ok "raw token not printed"

# ---- case 1b: недостающие серверы дописаны, порт — из .env второго мозга ----
[ "$(json_has "$TMP/lab/dev/.claude/.mcp.json" second_brain-tasks)" = "http://127.0.0.1:5999/mcp" ] \
  && ok "доска задач дописана с портом из \$SB_HOME/.env" \
  || bad "доска задач не дописана или порт не из .env: $(json_has "$TMP/lab/dev/.claude/.mcp.json" second_brain-tasks)"
[ -n "$(json_has "$TMP/lab/dev/.claude/.mcp.json" second_brain-memory_router)" ] \
  && ok "recall дописан в .mcp.json" || bad "recall не дописан"
echo "$out" | grep -q 'добавлены сервисы' && ok "добавленные сервисы названы в выводе" \
  || bad "добавленные сервисы не показаны: $out"

# ---- case 1c: adress-переменные дописаны в agent.env ------------------------
grep -q '^export SECOND_BRAIN_TASKS_URL=http://127.0.0.1:5999/mcp' "$TMP/lab/dev/.claude/agent.env" \
  && ok "agent.env: адрес доски задач дописан" || bad "agent.env: SECOND_BRAIN_TASKS_URL отсутствует"

# ---- case 1d: узкие scopes расширены до базовых -----------------------------
grep -q 'AGENT_SCOPES=.*task-board' "$TMP/lab/dev/.claude/agent.env" \
  && ok "scopes дополнены task-board" || bad "scopes не дополнены"
echo "$out" | grep -q 'scopes=decisions,knowledge,external' \
  && ok "прежние scopes сохранены и дополнены" || bad "scopes потеряли прежние значения: $out"

# ---- case 1e: агент перезапущен, раз сервисы отвечают -----------------------
grep -q 'restart claude-agent-dev.service' "$TMP/systemctl.log" \
  && ok "агент перезапущен при живых сервисах" || bad "рестарт не выполнен"

# ---- case 2: всё на месте → менять нечего, повторный рестарт не нужен -------
: > "$TMP/systemctl.log"
out="$(FAKE_TOKEN_VALID=1 run_sut 2>&1)"
echo "$out" | grep -q 'dev: уже подключён полностью' \
  && ok "полностью подключённый агент не трогается" || bad "не идемпотентно: $out"
grep -q 'restart claude-agent-dev.service' "$TMP/systemctl.log" \
  && bad "лишний рестарт агента" || ok "лишнего рестарта нет"

# ---- case 2a: токен оставлен, AGENT_SCOPES отстал от БД → строку сверяем ----
envf="$TMP/lab/dev/.claude/agent.env"
sed -i -E 's|^export AGENT_SCOPES=.*|export AGENT_SCOPES="decisions,knowledge"|' "$envf"
echo "old backup marker" > "$envf.bak-connect"
: > "$TMP/systemctl.log"
out="$(FAKE_TOKEN_VALID=1 run_sut 2>&1)"
echo "$out" | grep -q 'dev: AGENT_SCOPES в agent.env сверен с БД' \
  && ok "отставший AGENT_SCOPES замечен" || bad "расхождение AGENT_SCOPES с БД не замечено: $out"
grep -q "^export AGENT_SCOPES=\"$FULL_SCOPES\"" "$envf" \
  && ok "AGENT_SCOPES = права из БД" || bad "AGENT_SCOPES не сверен: $(grep AGENT_SCOPES "$envf")"
grep -q 'AGENT_SCOPES="decisions,knowledge"' "$envf.bak-connect" \
  && ok "бэкап снят свежий, перед правкой" || bad "бэкап устаревший: $(cat "$envf.bak-connect")"
grep -q 'restart claude-agent-dev.service' "$TMP/systemctl.log" \
  && bad "рестарт ради одной строки AGENT_SCOPES" || ok "сверка прав без рестарта агента"
ls "$TMP/lab/dev/.claude/" | grep -q 'pre-connect' \
  && bad "временная копия agent.env не убрана" || ok "временных копий agent.env не осталось"

# ---- case 2a': адрес дописан при живом токене → бэкап тоже свежий -----------
sed -i '/SECOND_BRAIN_TASKS_URL/d' "$envf"
echo "old backup marker" > "$envf.bak-connect"
out="$(FAKE_TOKEN_VALID=1 run_sut 2>&1)"
grep -q 'old backup marker' "$envf.bak-connect" \
  && bad "дописали адрес поверх старого бэкапа" || ok "бэкап обновлён перед дописыванием адреса"
grep -q 'SECOND_BRAIN_TASKS_URL' "$envf.bak-connect" \
  && bad "бэкап снят уже после правки" || ok "бэкап — состояние до правки"

# ---- case 2a'': перевыпуск берёт права из БД, а не из отставшей строки ------
sed -i -E 's|^export AGENT_SCOPES=.*|export AGENT_SCOPES="decisions"|' "$envf"
out="$(FAKE_TOKEN_VALID=1 FAKE_TOKEN_SCOPES="decisions,projects" run_sut 2>&1)"
echo "$out" | grep -q 'scopes=decisions,projects,' \
  && ok "выданное вручную право (projects) пережило перевыпуск" \
  || bad "перевыпуск по отставшей строке потерял права из БД: $out"

# ---- case 2b: валидный токен, но прав не хватает → переиздание --------------
out="$(FAKE_TOKEN_VALID=1 FAKE_TOKEN_SCOPES="decisions,knowledge" run_sut 2>&1)"
echo "$out" | grep -q 'прав не хватает' \
  && ok "нехватка прав в токене → переиздание" || bad "узкие права в токене не замечены: $out"

# ---- case 2c: stale token (not in DB, e.g. after reinstall) → reissue --------
out="$(FAKE_TOKEN_VALID=0 run_sut 2>&1)"
echo "$out" | grep -q 'dev: токена нет в БД' \
  && ok "stale token → reissue path" || bad "stale token not reissued: $out"
grep -q 'AGENT_BEARER="tok_dev_' "$TMP/lab/dev/.claude/agent.env" \
  && ok "stale token: agent.env re-patched" || bad "stale token: agent.env not patched"

# ---- case 3: сервисы молчат → токен ставим, агента НЕ рестартуем ------------
rm -rf "$TMP/lab"; mk_agent down CHANGE_ME
: > "$TMP/systemctl.log"
out="$(FAKE_SERVICES_UP=0 run_sut 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "молчащие сервисы не валят скрипт" || bad "exit $rc при молчащих сервисах"
echo "$out" | grep -q 'сервисы ещё не отвечают' \
  && ok "рестарт пропущен с объяснением" || bad "нет предупреждения о недоступных сервисах: $out"
grep -q 'restart claude-agent-down.service' "$TMP/systemctl.log" \
  && bad "агент перезапущен мимо неготовых сервисов" || ok "рестарт вслепую не выполнен"
grep -q 'AGENT_BEARER="tok_down_' "$TMP/lab/down/.claude/agent.env" \
  && ok "токен всё равно прописан" || bad "токен не прописан"

# ---- case 4: issuance failure → exit 1, others still processed --------------
rm -rf "$TMP/lab"; mk_agent broken CHANGE_ME
out="$(run_sut 2>&1)"; rc=$?
[ $rc -eq 1 ] && ok "exit 1 when issuance fails" || bad "expected exit 1, got $rc"
echo "$out" | grep -q 'broken: token issuance FAILED' \
  && ok "failure reported per-agent" || bad "failure not reported"

# ---- case 5: agent dir without agent.env is skipped -------------------------
rm -rf "$TMP/lab"; mkdir -p "$TMP/lab/shared/.claude"
out="$(run_sut 2>&1)"
echo "$out" | grep -q 'shared: no agent.env' && ok "non-wired dir skipped" || bad "non-wired dir not skipped"

# ---- case 5b: agent.env without AGENT_SCOPES → DEFAULT_SCOPES ---------------
rm -rf "$TMP/lab"; mkdir -p "$TMP/lab/noscope/.claude"
printf 'export AGENT_ID="noscope"\nexport AGENT_BEARER="CHANGE_ME"\n' > "$TMP/lab/noscope/.claude/agent.env"
printf '{"mcpServers":{"m":{"headers":{"Authorization":"Bearer CHANGE_ME"}}}}\n' > "$TMP/lab/noscope/.claude/.mcp.json"
out="$(SKIP_AGENT_RESTART=1 run_sut 2>&1)"; rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q "noscope: connected (scopes=$FULL_SCOPES" \
  && ok "no AGENT_SCOPES → default scopes" \
  || bad "no AGENT_SCOPES: rc=$rc, script died silently or ignored DEFAULT_SCOPES"

# ---- case 5c: битый .mcp.json — файл не перезаписываем, говорим оператору ---
rm -rf "$TMP/lab"; mkdir -p "$TMP/lab/brokenjson/.claude"
printf 'export AGENT_ID="brokenjson"\nexport AGENT_BEARER="CHANGE_ME"\n' > "$TMP/lab/brokenjson/.claude/agent.env"
printf 'not json at all\n' > "$TMP/lab/brokenjson/.claude/.mcp.json"
out="$(SKIP_AGENT_RESTART=1 run_sut 2>&1)"; rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q 'не удалось разобрать' \
  && ok "битый .mcp.json → внятная ошибка" || bad "битый .mcp.json обработан молча (rc=$rc): $out"
grep -q 'not json at all' "$TMP/lab/brokenjson/.claude/.mcp.json" \
  && ok "битый .mcp.json не перезаписан" || bad "битый .mcp.json затёрт"

# ---- case 6: no lab at all → clean exit 0 -----------------------------------
out="$(SB_HOME="$SB" SB_ETC="$TMP/etc" SECRETS="$TMP/etc/secrets.env" \
  SERVICE_USER="$(id -un)" AGENT_LAB_DIR="$TMP/nope" bash "$SUT" 2>&1)"; rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q 'nothing to connect' \
  && ok "missing lab → clean exit" || bad "missing lab handling broken (rc=$rc)"

echo
echo "passed=$pass failed=$fail"
[ $fail -eq 0 ]
