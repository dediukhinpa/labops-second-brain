#!/usr/bin/env bash
# Тест sync_repo_to_install_dir: повторная установка не стирает живые данные.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=sync-repo.sh
. "$HERE/sync-repo.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "✓ $*"; pass=$((pass + 1)); }
bad() { echo "✗ $*"; fail=$((fail + 1)); }

REPO="$TMP/repo"; DST="$TMP/opt"
mkdir -p "$REPO/services" "$REPO/vault-template/decisions" "$REPO/docs/vault"
echo new > "$REPO/services/app.py"
echo doc > "$REPO/docs/vault/guide.md"
mkdir -p "$DST/vault/decisions" "$DST/.cache/models" "$DST/.venv/bin" "$DST/secrets" \
         "$DST/services" "$DST/notes-vault/knowledge" "$DST/docs/vault"
echo note  > "$DST/vault/decisions/2026-09-01-x.md"
echo w     > "$DST/.cache/models/weights.onnx"
echo py    > "$DST/.venv/bin/python"
echo s     > "$DST/secrets/key"
echo e     > "$DST/.env"
echo old   > "$DST/services/removed.py"
echo n2    > "$DST/notes-vault/knowledge/k.md"
echo stale > "$DST/docs/vault/stale.md"

sync_repo_to_install_dir "$REPO" "$DST" "$DST/notes-vault"

[ -f "$DST/vault/decisions/2026-09-01-x.md" ] && ok "vault/ сохранён" || bad "vault/ стёрт"
[ -f "$DST/.cache/models/weights.onnx" ] && ok ".cache/ сохранён" || bad ".cache/ стёрт"
[ -f "$DST/.venv/bin/python" ] && ok ".venv/ сохранён" || bad ".venv/ стёрт"
[ -f "$DST/secrets/key" ] && ok "secrets/ сохранён" || bad "secrets/ стёрт"
[ -f "$DST/.env" ] && ok ".env сохранён" || bad ".env стёрт"
[ -f "$DST/notes-vault/knowledge/k.md" ] && ok "VAULT_ROOT внутри установки сохранён" \
  || bad "VAULT_ROOT под другим именем стёрт"
[ "$(cat "$DST/services/app.py")" = new ] && ok "код обновлён" || bad "код не скопирован"
[ ! -e "$DST/services/removed.py" ] && ok "удалённый из репо файл убран" \
  || bad "--delete не работает для кода"
[ ! -e "$DST/docs/vault/stale.md" ] && [ -f "$DST/docs/vault/guide.md" ] \
  && ok "вложенная docs/vault/ синхронизируется как обычно" \
  || bad "исключение vault/ задело вложенную папку"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
