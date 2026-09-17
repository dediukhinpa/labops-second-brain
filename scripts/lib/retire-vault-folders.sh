# shellcheck shell=bash
# retire_vault_folders <vault-root> <backup-dir>
#
# Переносит заметки из папок, снятых миграцией 011 (strategy, system, metrics,
# external, tasks и их числовые старые имена), в knowledge/ — тем же путём, что
# миграция пишет в documents.path, чтобы vault и база не разошлись. Перед
# переносом кладёт tar-копию папок в <backup-dir>. Файл, чьё место в knowledge/
# уже занято, не трогает и называет — его разбирает оператор. Служебные
# README.md и index.md верхнего уровня и все .gitkeep удаляются (vault засевается
# из шаблона, .gitkeep лежит и в knowledge/ — иначе он «конфликтовал» бы
# с собой, и папки не снимались бы никогда), пустые папки — тоже.
#
# Порядок RETIRED_VAULT_FOLDERS совпадает с ord в миграции 011: если две
# снятые папки дают один путь в knowledge/, и файл, и строка базы достаются
# первой по этому порядку.
# Печатает итог; код возврата 1, если что-то осталось на месте.
RETIRED_VAULT_FOLDERS=(strategy system metrics external tasks
                       10-strategy 10-system 20-metrics 50-external 60-tasks)

retire_vault_folders() {
  local vault="$1" backup_dir="$2" old rel target stamp left=0
  local -a present=()
  for old in "${RETIRED_VAULT_FOLDERS[@]}"; do
    [ -d "$vault/$old" ] && present+=("$old")
  done
  [ "${#present[@]}" -eq 0 ] && return 0

  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$backup_dir"
  tar -C "$vault" -czf "$backup_dir/vault-retired-folders-$stamp.tar.gz" "${present[@]}"
  chmod 600 "$backup_dir/vault-retired-folders-$stamp.tar.gz"
  echo "  копия снятых папок: $backup_dir/vault-retired-folders-$stamp.tar.gz"

  for old in "${present[@]}"; do
    rm -f "$vault/$old/README.md" "$vault/$old/index.md"
    find "$vault/$old" -type f -name .gitkeep -delete
    while IFS= read -r -d '' rel; do
      rel="${rel#./}"
      target="$vault/knowledge/$rel"
      if [ -e "$target" ]; then
        echo "  оставлен: $old/$rel — knowledge/$rel уже существует"
        left=1
        continue
      fi
      mkdir -p "$(dirname "$target")"
      mv "$vault/$old/$rel" "$target"
      echo "  перенесён: $old/$rel → knowledge/$rel"
    done < <(cd "$vault/$old" && find . -type f -print0)
    find "$vault/$old" -depth -type d -empty -delete
    [ -d "$vault/$old" ] && left=1
  done
  return "$left"
}
