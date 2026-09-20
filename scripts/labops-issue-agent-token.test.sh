#!/usr/bin/env bash
# Unit-тесты labops-issue-agent-token.sh — выдача токена агенту от root.
# Гоняются не от root: пути мозга подменены через LABOPS_TOKEN_HELPER_CONF, а
# SERVICE_USER в настройках равен текущему пользователю, поэтому runuser не нужен.
# Главное: скоупы и имя агента проверяются ДО обращения к базе, а '*' не проходит.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HELPER="$HERE/labops-issue-agent-token.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

ME="$(id -un)"
INSTALL_DIR="$TMP/second_brain"
mkdir -p "$INSTALL_DIR/.venv/bin" "$INSTALL_DIR/scripts"
# Заглушка вместо issue-agent-token.py: печатает токен и записывает аргументы.
cat > "$INSTALL_DIR/.venv/bin/python" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TMP/args"
echo sb_fake_token_value
EOF
chmod +x "$INSTALL_DIR/.venv/bin/python"
touch "$INSTALL_DIR/scripts/issue-agent-token.py"

CONF="$TMP/token-helper.conf"
printf 'INSTALL_DIR=%s\nSERVICE_USER=%s\n' "$INSTALL_DIR" "$ME" > "$CONF"

run() {  # run <args...> — код в RC, stdout в $TMP/out, stderr в $TMP/err
  RC=0
  LABOPS_TOKEN_HELPER_CONF="$CONF" bash "$HELPER" "$@" \
    >"$TMP/out" 2>"$TMP/err" </dev/null || RC=$?
}

# 1. Обычная выдача: токен в stdout, скоупы по умолчанию.
run developer
[ "$RC" -eq 0 ] || fail "обычная выдача упала: $(cat "$TMP/err")"
[ "$(cat "$TMP/out")" = "sb_fake_token_value" ] || fail "токен не отдан в stdout"
grep -q -- '--agent' "$TMP/args" || fail "не передан --agent"
grep -q 'developer' "$TMP/args" || fail "не передано имя агента"
grep -q 'decisions,knowledge,inbox,error-patterns,task-board,personal,projects,daily' "$TMP/args" \
  || fail "не переданы скоупы по умолчанию: $(cat "$TMP/args")"
# Токен не должен попасть в журнал (stderr).
grep -q 'sb_fake_token_value' "$TMP/err" && fail "токен утёк в stderr"

# 2. Свой набор скоупов из канонического списка.
run analyst knowledge,daily
[ "$RC" -eq 0 ] || fail "свои скоупы не приняты: $(cat "$TMP/err")"
grep -q 'knowledge,daily' "$TMP/args" || fail "переданы не те скоупы"

# 3. Повышение прав не проходит.
rm -f "$TMP/args"
run developer '*'
[ "$RC" -ne 0 ] || fail "принята звёздочка в скоупах"
[ ! -f "$TMP/args" ] || fail "звёздочка дошла до issue-agent-token.py"
run developer knowledge,admin
[ "$RC" -ne 0 ] || fail "принят неизвестный скоуп"
run developer 'knowledge, daily'
[ "$RC" -ne 0 ] || fail "принят скоуп с пробелом"

# 4. Имя агента и число аргументов проверяются.
run '../../etc/passwd'
[ "$RC" -ne 0 ] || fail "принято имя агента с путём"
run 'Developer'
[ "$RC" -ne 0 ] || fail "принято имя агента с заглавной буквы"
run ''
[ "$RC" -ne 0 ] || fail "принято пустое имя агента"
run developer knowledge extra
[ "$RC" -ne 0 ] || fail "принят лишний аргумент"

# 5. Настройки: без файла и с непригодными путями — внятный отказ.
printf 'INSTALL_DIR=%s/../second_brain\nSERVICE_USER=%s\n' "$TMP" "$ME" > "$CONF"
run developer
[ "$RC" -ne 0 ] || fail "принят INSTALL_DIR с '..'"
printf 'INSTALL_DIR=second_brain\nSERVICE_USER=%s\n' "$ME" > "$CONF"
run developer
[ "$RC" -ne 0 ] || fail "принят относительный INSTALL_DIR"
rm -f "$CONF"
run developer
[ "$RC" -ne 0 ] && grep -q 'install.sh' "$TMP/err" || fail "без настроек: нет внятного отказа"

# 6. Мозг установлен не полностью — говорим об этом, а не падаем трассировкой.
printf 'INSTALL_DIR=%s\nSERVICE_USER=%s\n' "$TMP/missing" "$ME" > "$CONF"
run developer
[ "$RC" -ne 0 ] && grep -q 'не полностью' "$TMP/err" || fail "нет внятного отказа без venv"

echo "labops-issue-agent-token: ok"
