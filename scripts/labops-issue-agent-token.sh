#!/usr/bin/env bash
# Выдача Bearer-токена агенту от root по узкому правилу sudo.
#
# issue-agent-token.py читает $INSTALL_DIR/.env с доступом к базе, а он
# 0600 second_brain:second_brain. Пользователь агента прочитать его не может,
# поэтому скилл create-agent на чужом сервере оставлял в agent.env CHANGE_ME:
# новый агент поднимался без общей памяти, и это чинили руками.
#
# scripts/install.sh кладёт этот файл в /usr/local/sbin/labops-issue-agent-token
# и выдаёт пользователю агента NOPASSWD ровно на него. Правило указывает
# команду без аргументов (иначе sudo-rs не принимает sudoers со звёздочкой),
# поэтому аргументы проверяет сам хелпер:
#   • имя агента — строгий шаблон, без путей и пробелов;
#   • скоупы — только из канонического списка, '*' не принимается, иначе агент
#     выписал бы себе администраторский токен.
#
# Пути берутся из /etc/second_brain/token-helper.conf, который пишет root при
# установке, — вызывающий подменить их не может.
#
# Использование (от пользователя агента или root):
#   sudo -n /usr/local/sbin/labops-issue-agent-token <agent-id> [scopes]
# Токен печатается в stdout ровно один раз, в журналы не попадает.
set -euo pipefail

CONF="/etc/second_brain/token-helper.conf"
# Подмена — только для тестов без root. От root переменные окружения
# игнорируются: иначе вызывающий подсунул бы свой issue-agent-token.py.
if [ "$(id -u)" -ne 0 ]; then
  CONF="${LABOPS_TOKEN_HELPER_CONF:-$CONF}"
fi

# Канонические скоупы second_brain (services/shared/scopes.py).
# Соответствие проверяется тестом tests/test_shell_scripts.py.
CANONICAL_SCOPES="personal daily decisions projects knowledge task-board error-patterns inbox"
DEFAULT_SCOPES="decisions,knowledge,inbox,error-patterns,task-board,personal,projects,daily"
AGENT_RE='^[a-z][a-z0-9_-]{0,63}$'
PATH_RE='^/[A-Za-z0-9._/-]+$'
NAME_RE='^[A-Za-z_][A-Za-z0-9_-]*$'

log() { printf '[token] %s\n' "$*" >&2; }
die() { printf '[token ОШИБКА] %s\n' "$*" >&2; exit 1; }

AGENT="${1:-}"
SCOPES="${2:-$DEFAULT_SCOPES}"
[ "$#" -le 2 ] || die "использование: labops-issue-agent-token <agent-id> [scopes]"
[ -n "$AGENT" ] || die "использование: labops-issue-agent-token <agent-id> [scopes]"
[[ "$AGENT" =~ $AGENT_RE ]] || die "недопустимое имя агента: $AGENT"

# '*' и неизвестные имена отбиваем здесь: issue-agent-token.py принимает их
# как есть, а токен со звёздочкой даёт доступ к любому скоупу.
IFS=',' read -r -a _req <<< "$SCOPES"
[ "${#_req[@]}" -gt 0 ] || die "пустой список скоупов"
for scope in "${_req[@]}"; do
  [ -n "$scope" ] || die "пустой скоуп в списке: $SCOPES"
  case " $CANONICAL_SCOPES " in
    *" $scope "*) ;;
    *) die "неизвестный скоуп: $scope (разрешены: $CANONICAL_SCOPES)" ;;
  esac
done

[ -f "$CONF" ] || die "нет $CONF — перезапустите scripts/install.sh мозга"
if [ "$(id -u)" -eq 0 ]; then
  [ "$(stat -c %u "$CONF")" = 0 ] || die "$CONF принадлежит не root"
  case "$(stat -c %A "$CONF")" in
    ?????w????|????????w?) die "$CONF доступен на запись не только root" ;;
  esac
fi
conf_val() {  # $1=ключ — значение; файл читается, а не исполняется
  { grep -E "^$1=" "$CONF" || true; } | tail -n 1 | sed -E "s/^$1=//; s/^\"//; s/\"$//"
}
INSTALL_DIR="$(conf_val INSTALL_DIR)"
SERVICE_USER="$(conf_val SERVICE_USER)"
[[ "$INSTALL_DIR" =~ $PATH_RE ]] || die "недопустимый INSTALL_DIR в $CONF: $INSTALL_DIR"
[[ "$SERVICE_USER" =~ $NAME_RE ]] || die "недопустимый SERVICE_USER в $CONF: $SERVICE_USER"
case "/$INSTALL_DIR/" in */../*) die "путь с '..' не принимается: $INSTALL_DIR" ;; esac

PYTHON="$INSTALL_DIR/.venv/bin/python"
SCRIPT="$INSTALL_DIR/scripts/issue-agent-token.py"
[ -x "$PYTHON" ] || die "нет $PYTHON — мозг установлен не полностью"
[ -f "$SCRIPT" ] || die "нет $SCRIPT — мозг установлен не полностью"

# Скрипт читает .env владельца, поэтому запускаем от него, а не от root:
# так же это делает docs/setup.md.
log "выдаю токен агенту $AGENT (скоупы: $SCOPES)"
if [ "$(id -un)" = "$SERVICE_USER" ]; then
  exec "$PYTHON" "$SCRIPT" --agent "$AGENT" --scopes "$SCOPES"
fi
exec runuser -u "$SERVICE_USER" -- "$PYTHON" "$SCRIPT" --agent "$AGENT" --scopes "$SCOPES"
