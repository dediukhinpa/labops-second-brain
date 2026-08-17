-- 009_embedding_dim_768.sql
-- Switch chunks.embedding from vector(1024) to vector(768): FASTEMBED_MODEL
-- moves from intfloat/multilingual-e5-large (2.24GB ONNX weights, ~2.9GB
-- resident) to sentence-transformers/paraphrase-multilingual-mpnet-base-v2
-- (1.0GB ONNX weights) to fit the VPS's memory budget without swapping.
--
-- Existing 1024-dim vectors are meaningless under the new model regardless of
-- dimension, so this truncates chunks (cheap: content is re-derived from the
-- vault on re-embed) and requeues every document. ingest_worker picks up the
-- pending jobs on its normal poll cycle and regenerates chunks + embeddings
-- with the new model. Idempotent to replay: TRUNCATE and the index DDL are
-- safe re-run, and the INSERT ... ON CONFLICT DO NOTHING re-queues only docs
-- that aren't already pending.

BEGIN;

TRUNCATE TABLE chunks;

DROP INDEX IF EXISTS idx_chunks_embedding_hnsw;

ALTER TABLE chunks ALTER COLUMN embedding TYPE vector(768);

CREATE INDEX IF NOT EXISTS idx_chunks_embedding_hnsw
    ON chunks
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

INSERT INTO embedding_jobs (doc_id, status)
SELECT id, 'pending' FROM documents
ON CONFLICT (doc_id, status) DO NOTHING;

COMMIT;
