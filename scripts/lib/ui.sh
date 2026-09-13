#!/usr/bin/env bash
# Единый вид вывода установки second-brain — тот же, что у labops-ai-assistant
# (agent-architecture/orchestration/lib/ui.sh), чтобы оператор, ставящий обе
# части подряд, видел одни значки и цвета.
#
# Раньше здесь были «[install 12:00:00Z] …», «log "WARNING: …"» обычным текстом
# и отдельный словарь PASS/WARN/FAIL в verify.sh — предупреждение ничем не
# выделялось среди сотни строк apt и pip.
#
# Значки:
#   ▶  раздел            ✓  готово             ⚠  проблема, требует внимания
#   ✗  ошибка (die — с выходом, err — без)
#   →  выполняю действие  ℹ  справка, ничего делать не нужно
#   [?] вопрос           [=] ответ подставлен без вопроса (NONINTERACTIVE / env)
#
# Репозитории ставятся независимо, поэтому это копия, а не общий файл: блок
# между ui:begin и ui:end обязан совпадать с оригиналом построчно
# (tests/test_install_output.py сверяет его с эталоном ниже и, если рядом лежит
# labops-ai-assistant, — с самим оригиналом).

# shellcheck shell=bash

# ui:begin — от этой метки до ui:end test.sh сверяет с tg-plugin/install.sh.
UI_SECTION='\033[1;36m'; UI_OK='\033[0;32m'; UI_WARN='\033[1;33m'; UI_ERR='\033[1;31m'
UI_INFO='\033[0;36m'; UI_BOLD='\033[1m'; UI_RESET='\033[0m'
say()  { printf "\n${UI_SECTION}▶ %s${UI_RESET}\n" "$*"; }
ok()   { printf "${UI_OK}✓ %s${UI_RESET}\n" "$*"; }
warn() { printf "${UI_WARN}⚠ %s${UI_RESET}\n" "$*"; }
die()  { printf "${UI_ERR}✗ %s${UI_RESET}\n" "$*" >&2; exit 1; }
step() { printf "${UI_INFO}→ %s${UI_RESET}\n" "$*"; }
note() { printf "${UI_INFO}ℹ %s${UI_RESET}\n" "$*"; }
err()  { printf "${UI_ERR}✗ %s${UI_RESET}\n" "$*" >&2; }
ask_text() { printf "${UI_INFO}[?]${UI_RESET} %s: " "$2"; read -r "$1" || true; }
# ui:end

# ask_yn <переменная> <вопрос> <y|n> — вопрос да/нет, в переменную пишется y или n.
# Уже заданная переменная и NONINTERACTIVE=1 — без вопроса; закрытый stdin —
# ответ по умолчанию (read под set -e иначе оборвал бы установку посередине).
# Непонятный ответ переспрашивается, а не трактуется молча как «да».
# UI_ASK_EOF=1 после вызова — ввода не было (stdin закрыт), ответ взят по умолчанию.
ask_yn() {
  local __v="$1" __q="$2" __d="$3" __i=""
  UI_ASK_EOF=0
  case "${!__v:-}" in
    y|Y|yes|Yes|YES|1) printf -v "$__v" y; return 0 ;;
    n|N|no|No|NO|0)    printf -v "$__v" n; return 0 ;;
  esac
  if [ "${NONINTERACTIVE:-0}" = "1" ]; then
    printf -v "$__v" '%s' "$__d"
    printf "${UI_INFO}[=]${UI_RESET} %s: %s\n" "$__q" "$__d"
    return 0
  fi
  while :; do
    printf "${UI_INFO}[?]${UI_RESET} %s [y/n]: " "$__q"
    if ! read -r __i; then echo; UI_ASK_EOF=1; printf -v "$__v" '%s' "$__d"; return 0; fi
    # Варианты перечислены целиком: ${var,,} и [дД] в локали C кириллицу
    # не понимают — там это байты, а не буквы.
    case "$__i" in
      "")                               printf -v "$__v" '%s' "$__d"; return 0 ;;
      y|Y|yes|Yes|YES|д|Д|да|Да|ДА)     printf -v "$__v" y; return 0 ;;
      n|N|no|No|NO|н|Н|нет|Нет|НЕТ)     printf -v "$__v" n; return 0 ;;
    esac
    echo "    ответьте y или n"
  done
}
