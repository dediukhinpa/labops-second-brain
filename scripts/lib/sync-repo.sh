# shellcheck shell=bash
# sync_repo_to_install_dir <repo-root> <install-dir> [vault-root]
#
# Копирует репозиторий в каталог установки с --delete, но не трогает то, чего
# в репозитории нет по определению: живой vault (единственный источник правды),
# кэш весов FastEmbed, .venv, .env, secrets/. Раньше исключения не покрывали
# vault/ и .cache/, и повторный install.sh стирал vault целиком: rsync --delete
# удаляет в приёмнике всё, чего нет в источнике, если это не исключено.
# Исключения якорные («/vault/»): вложенная папка с тем же именем в репо
# копируется как обычно.
sync_repo_to_install_dir() {
  local src="$1" dst="$2" vault="${3:-}"
  local -a protect=(
    --exclude '.git'
    --exclude '__pycache__'
    --exclude '*.pyc'
    --exclude '/.venv/'
    --exclude '/.env'
    --exclude '/secrets/'
    --exclude '/vault/'
    --exclude '/.cache/'
    --exclude '/.pytest_cache/'
  )
  # VAULT_ROOT может лежать внутри каталога установки под другим именем.
  case "$vault" in
    "$dst"/?*) protect+=(--exclude "/${vault#"$dst"/}/") ;;
  esac
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "${protect[@]}" "$src/" "$dst/"
  else
    # Без rsync удалений нет вовсе — только докопировать поверх.
    cp -a "$src/." "$dst/"
  fi
}
