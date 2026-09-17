-- 011_retire_unused_scopes.sql
-- Retire the 'strategy', 'system', 'metrics', 'external' and 'tasks' scopes.
-- On a standard deploy (SECOND_BRAIN_TOOLS=core) no tool wrote to any of them:
-- strategy/system/metrics/tasks never had a write tool, and
-- create_external_note was hidden behind SECOND_BRAIN_TOOLS=all and is now
-- removed. The scopes only padded agent tokens and left empty vault folders.
-- Anything already stored there moves to 'knowledge' — the same fit that
-- migration 008 chose for 'runbooks'.
--
-- services.shared.scopes.SCOPE_ALIASES maps every retired name (and its legacy
-- numbered form) to 'knowledge' at runtime, so this is safe to run with
-- services live; it makes the STORED values canonical. Idempotent.
--
-- The vault files themselves are NOT moved here — the database cannot touch
-- the filesystem. Move vault/<old>/* into vault/knowledge/ before or right after
-- running this (see docs/troubleshooting.md, "Retired scopes").

BEGIN;

CREATE TEMP TABLE _retired_map(old text PRIMARY KEY) ON COMMIT DROP;
INSERT INTO _retired_map(old) VALUES
    ('strategy'), ('system'), ('metrics'), ('external'), ('tasks'),
    ('10-strategy'), ('10-system'), ('20-metrics'), ('50-external'), ('60-tasks');

-- 1) documents.scope
UPDATE documents d
   SET scope = 'knowledge'
  FROM _retired_map m
 WHERE d.scope = m.old;

-- 2) documents.path — rewrite the leading "<old>/" folder segment. Path is
-- UNIQUE, so skip any row that would collide with an existing knowledge/ file
-- of the same name; those need a manual rename (rare — flag for review).
UPDATE documents d
   SET path = 'knowledge' || substr(d.path, length(m.old) + 1)
  FROM _retired_map m
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
             LEFT JOIN _retired_map m ON m.old = u.s
             GROUP BY 1
           ) dedup
       )
 WHERE t.can_write_scopes IS NOT NULL
   AND EXISTS (SELECT 1 FROM unnest(t.can_write_scopes) s
                JOIN _retired_map m ON m.old = s);

UPDATE agent_tokens t
   SET can_read_scopes = (
         SELECT COALESCE(array_agg(DISTINCT_S ORDER BY min_ord), '{}'::text[])
           FROM (
             SELECT
               CASE WHEN m.old IS NOT NULL THEN 'knowledge' ELSE u.s END AS DISTINCT_S,
               min(u.ord) AS min_ord
             FROM unnest(t.can_read_scopes) WITH ORDINALITY AS u(s, ord)
             LEFT JOIN _retired_map m ON m.old = u.s
             GROUP BY 1
           ) dedup
       )
 WHERE t.can_read_scopes IS NOT NULL
   AND EXISTS (SELECT 1 FROM unnest(t.can_read_scopes) s
                JOIN _retired_map m ON m.old = s);

COMMIT;
