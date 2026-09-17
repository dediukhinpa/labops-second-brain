#!/usr/bin/env bash
# Тест миграции 011 на временном кластере Postgres: снятые папки уходят в
# knowledge/, общий новый путь не валит миграцию, повторный запуск безопасен.
# Без initdb (нет серверного Postgres) тест пропускается.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pg_bin="$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)"
if [ -z "$pg_bin" ] || [ ! -x "$pg_bin/initdb" ]; then
  echo "skip: нет initdb — миграция 011 не проверялась"
  exit 0
fi
# Случайный порт: фиксированный мог быть занят параллельным прогоном.
pg_port=$((20000 + RANDOM % 20000))

TMP="$(mktemp -d)"
"$pg_bin/initdb" -D "$TMP/data" -U postgres -A trust >/dev/null
"$pg_bin/pg_ctl" -D "$TMP/data" -o "-k $TMP -c listen_addresses='' -p $pg_port" \
  -l "$TMP/log" start >/dev/null
trap '"$pg_bin/pg_ctl" -D "$TMP/data" stop -m fast >/dev/null; rm -rf "$TMP"' EXIT

psql_q() { psql -h "$TMP" -p "$pg_port" -U postgres -v ON_ERROR_STOP=1 -qAt "$@"; }
pass=0; fail=0
ok()  { echo "✓ $*"; pass=$((pass + 1)); }
bad() { echo "✗ $*"; fail=$((fail + 1)); }

psql_q -c "CREATE ROLE second_brain" -c "CREATE DATABASE sb"
for f in "$REPO_ROOT"/migrations/0*.sql; do
  case "$f" in *011_*) continue ;; esac
  psql_q -d sb -f "$f" >/dev/null 2>&1
done

psql_q -d sb >/dev/null <<'SQL'
INSERT INTO documents (path, frontmatter, body, sha256, source_type, agent, scope) VALUES
 ('external/x.md',    '{}', 'a', 'h1', 'external',  'a', 'external'),
 ('50-external/x.md', '{}', 'b', 'h2', 'external',  'a', '50-external'),
 ('strategy/a.md',    '{}', 'c', 'h3', 'knowledge', 'a', 'strategy'),
 ('system/a.md',      '{}', 'd', 'h4', 'knowledge', 'a', 'system'),
 ('knowledge/k.md',   '{}', 'e', 'h5', 'knowledge', 'a', 'knowledge'),
 ('tasks/k.md',       '{}', 'f', 'h6', 'knowledge', 'a', 'tasks'),
 ('decisions/d.md',   '{}', 'g', 'h7', 'decision',  'a', 'decisions');
INSERT INTO agent_tokens (agent, token_sha256, can_write_scopes, can_read_scopes) VALUES
 ('t1', 's1', '{decisions,external,knowledge,50-external,strategy}', '{external,decisions}');
SQL

MIG="$REPO_ROOT/migrations/011_retire_unused_scopes.sql"
if psql_q -d sb -f "$MIG" >/dev/null 2>"$TMP/err"; then
  ok "миграция прошла при общем новом пути у двух снятых папок"
else
  bad "миграция упала: $(cat "$TMP/err")"
fi
psql_q -d sb -f "$MIG" >/dev/null 2>&1 && ok "повторный запуск безопасен" || bad "повторный запуск упал"

paths="$(psql_q -d sb -c "SELECT string_agg(path, ' ' ORDER BY path) FROM documents")"
[ "$paths" = "50-external/x.md decisions/d.md knowledge/a.md knowledge/k.md knowledge/x.md system/a.md tasks/k.md" ] \
  && ok "пути: первая по порядку папка переехала, конфликтные остались" || bad "пути: $paths"
[ "$(psql_q -d sb -c "SELECT body FROM documents WHERE path = 'knowledge/x.md'")" = a ] \
  && [ "$(psql_q -d sb -c "SELECT body FROM documents WHERE path = 'knowledge/a.md'")" = c ] \
  && ok "общий путь достался external и strategy (как в retire-vault-folders.sh)" \
  || bad "общий путь достался не той папке"
[ "$(psql_q -d sb -c "SELECT count(*) FROM documents WHERE scope <> 'decisions' AND scope <> 'knowledge'")" = 0 ] \
  && ok "documents.scope сведён к knowledge" || bad "остались снятые scope"
[ "$(psql_q -d sb -c "SELECT can_write_scopes::text || can_read_scopes::text FROM agent_tokens")" \
  = "{decisions,knowledge}{knowledge,decisions}" ] \
  && ok "токены: снятые области заменены knowledge без дублей" \
  || bad "токены: $(psql_q -d sb -c "SELECT can_write_scopes, can_read_scopes FROM agent_tokens")"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
