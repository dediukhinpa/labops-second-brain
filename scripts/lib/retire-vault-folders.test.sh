#!/usr/bin/env bash
# Тест retire_vault_folders: заметки переезжают в knowledge/, конфликты не затираются.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=retire-vault-folders.sh
. "$HERE/retire-vault-folders.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "✓ $*"; pass=$((pass + 1)); }
bad() { echo "✗ $*"; fail=$((fail + 1)); }

V="$TMP/vault"; B="$TMP/backups"
mkdir -p "$V/knowledge" "$V/decisions" "$V/strategy" "$V/external/twitter" "$V/metrics" "$V/tasks"
echo keep   > "$V/decisions/d.md"
echo readme > "$V/strategy/README.md"
echo plan   > "$V/strategy/plan.md"
echo post   > "$V/external/twitter/2026-01-01-post.md"
echo readme > "$V/metrics/README.md"
echo mine   > "$V/knowledge/dup.md"
echo theirs > "$V/tasks/dup.md"

rc=0; out="$(retire_vault_folders "$V" "$B")" || rc=$?

[ "$(cat "$V/knowledge/plan.md" 2>/dev/null)" = plan ] && ok "strategy/plan.md → knowledge/" \
  || bad "strategy/plan.md не перенесён"
[ -f "$V/knowledge/twitter/2026-01-01-post.md" ] && ok "вложенный путь сохранён, как в миграции" \
  || bad "external/twitter/… не перенесён"
[ ! -e "$V/strategy" ] && [ ! -e "$V/external" ] && [ ! -e "$V/metrics" ] \
  && ok "опустевшие папки удалены" || bad "снятые папки остались"
[ "$(cat "$V/knowledge/dup.md")" = mine ] && ok "занятое место в knowledge/ не затёрто" \
  || bad "конфликт затёр чужой файл"
[ -f "$V/tasks/dup.md" ] && echo "$out" | grep -q 'оставлен: tasks/dup.md' \
  && ok "конфликтный файл оставлен и назван" || bad "конфликт не показан: $out"
[ "$rc" -eq 1 ] && ok "код 1, пока что-то осталось" || bad "код $rc при конфликте"
[ -f "$V/decisions/d.md" ] && ok "живые папки не тронуты" || bad "задета папка decisions"
tar -tzf "$B"/vault-retired-folders-*.tar.gz | grep -q 'strategy/plan.md' \
  && ok "резервная копия содержит снятые папки" || bad "нет резервной копии"

rm -f "$V/tasks/dup.md"; rmdir "$V/tasks"
rc=0; retire_vault_folders "$V" "$B" >/dev/null || rc=$?
[ "$rc" -eq 0 ] && ok "повторный запуск без снятых папок — ничего не делает" \
  || bad "повторный запуск вернул $rc"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
