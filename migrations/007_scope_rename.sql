-- 007_scope_rename.sql
-- Rename Johnny-Decimal-style numbered vault scopes to plain semantic names.
--
-- The numbers were opaque to the system (RBAC/recall/ingest treat a scope as an
-- opaque string) and applied inconsistently. Scopes are now semantic names.
--
-- The application normalises legacy names at runtime (services.shared.scopes), so
-- this migration is safe to run with services live; it simply makes the STORED
-- values canonical, after which the alias layer is a no-op. Idempotent: rows that
-- already carry the semantic name are left untouched.
--
-- Note the two "tasks" concepts split apart:
--   60-tasks (vault content folder) -> tasks
--   10-tasks (Postgres task board)   -> task-board

BEGIN;

CREATE TEMP TABLE _scope_map(old text PRIMARY KEY, new text) ON COMMIT DROP;
INSERT INTO _scope_map(old, new) VALUES
  ('10-strategy', 'strategy'),
  ('10-system', 'system'),
  ('15-personal', 'personal'),
  ('20-daily', 'daily'),
  ('20-metrics', 'metrics'),
  ('30-decisions', 'decisions'),
  ('40-projects', 'projects'),
  ('50-external', 'external'),
  ('50-knowledge', 'knowledge'),
  ('60-tasks', 'tasks'),
  ('10-tasks', 'task-board'),
  ('70-runbooks', 'runbooks'),
  ('80-error-patterns', 'error-patterns'),
  ('90-inbox', 'inbox');

-- 1) documents.scope
UPDATE documents d
   SET scope = m.new
  FROM _scope_map m
 WHERE d.scope = m.old;

-- 2) documents.path — rewrite the leading "<old>/" folder segment (path is UNIQUE)
UPDATE documents d
   SET path = m.new || substr(d.path, length(m.old) + 1)
  FROM _scope_map m
 WHERE d.path LIKE m.old || '/%';

-- 3) agent_tokens arrays — rewrite each element, preserving order
UPDATE agent_tokens t
   SET can_write_scopes = (
         SELECT COALESCE(array_agg(COALESCE(m.new, u.s) ORDER BY u.ord), '{}'::text[])
           FROM unnest(t.can_write_scopes) WITH ORDINALITY AS u(s, ord)
           LEFT JOIN _scope_map m ON m.old = u.s
       )
 WHERE t.can_write_scopes IS NOT NULL
   AND EXISTS (SELECT 1 FROM unnest(t.can_write_scopes) s
                JOIN _scope_map m ON m.old = s);

UPDATE agent_tokens t
   SET can_read_scopes = (
         SELECT COALESCE(array_agg(COALESCE(m.new, u.s) ORDER BY u.ord), '{}'::text[])
           FROM unnest(t.can_read_scopes) WITH ORDINALITY AS u(s, ord)
           LEFT JOIN _scope_map m ON m.old = u.s
       )
 WHERE t.can_read_scopes IS NOT NULL
   AND EXISTS (SELECT 1 FROM unnest(t.can_read_scopes) s
                JOIN _scope_map m ON m.old = s);

COMMIT;
