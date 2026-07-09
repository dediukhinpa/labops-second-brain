-- 008_remove_runbooks_scope.sql
-- Retire the 'runbooks' scope (folder + create_runbook_note tool saw no real
-- usage). Everything that used to live under runbooks/ now belongs in
-- knowledge/ — the closest remaining semantic fit.
--
-- services.shared.scopes.SCOPE_ALIASES already maps 'runbooks' and the legacy
-- '70-runbooks' to 'knowledge' at runtime, so this migration is safe to run
-- with services live; it just makes the STORED values canonical. Idempotent:
-- rows that carry neither legacy name are left untouched.

BEGIN;

CREATE TEMP TABLE _runbooks_map(old text PRIMARY KEY) ON COMMIT DROP;
INSERT INTO _runbooks_map(old) VALUES ('runbooks'), ('70-runbooks');

-- 1) documents.scope
UPDATE documents d
   SET scope = 'knowledge'
  FROM _runbooks_map m
 WHERE d.scope = m.old;

-- 2) documents.path — rewrite the leading "<old>/" folder segment. Path is
-- UNIQUE, so skip any row that would collide with an existing knowledge/ file
-- of the same name; those need a manual rename (rare — flag for review).
UPDATE documents d
   SET path = 'knowledge' || substr(d.path, length(m.old) + 1)
  FROM _runbooks_map m
 WHERE d.path LIKE m.old || '/%'
   AND NOT EXISTS (
         SELECT 1 FROM documents d2
          WHERE d2.path = 'knowledge' || substr(d.path, length(m.old) + 1)
       );

-- 3) agent_tokens arrays — replace with 'knowledge', then dedup (a token may
-- already grant 'knowledge' separately) while preserving first-seen order.
UPDATE agent_tokens t
   SET can_write_scopes = (
         SELECT COALESCE(array_agg(DISTINCT_S ORDER BY min_ord), '{}'::text[])
           FROM (
             SELECT
               CASE WHEN m.old IS NOT NULL THEN 'knowledge' ELSE u.s END AS DISTINCT_S,
               min(u.ord) AS min_ord
             FROM unnest(t.can_write_scopes) WITH ORDINALITY AS u(s, ord)
             LEFT JOIN _runbooks_map m ON m.old = u.s
             GROUP BY 1
           ) dedup
       )
 WHERE t.can_write_scopes IS NOT NULL
   AND EXISTS (SELECT 1 FROM unnest(t.can_write_scopes) s
                JOIN _runbooks_map m ON m.old = s);

UPDATE agent_tokens t
   SET can_read_scopes = (
         SELECT COALESCE(array_agg(DISTINCT_S ORDER BY min_ord), '{}'::text[])
           FROM (
             SELECT
               CASE WHEN m.old IS NOT NULL THEN 'knowledge' ELSE u.s END AS DISTINCT_S,
               min(u.ord) AS min_ord
             FROM unnest(t.can_read_scopes) WITH ORDINALITY AS u(s, ord)
             LEFT JOIN _runbooks_map m ON m.old = u.s
             GROUP BY 1
           ) dedup
       )
 WHERE t.can_read_scopes IS NOT NULL
   AND EXISTS (SELECT 1 FROM unnest(t.can_read_scopes) s
                JOIN _runbooks_map m ON m.old = s);

COMMIT;
