-- 010_reembed_int8.sql
-- Requeue every document so its chunks are re-embedded with the int8 ONNX
-- variant of the same model (FASTEMBED_ONNX_FILE=onnx/model_quantized.onnx).
--
-- The dimension does not change (768 both ways), so no column or index DDL is
-- needed. The int8 vectors are close but not identical to the fp32 ones
-- (cosine 0.9945 on probe texts), and mixing two generations inside one index
-- makes ranking depend on when a note happened to be indexed — so every
-- document is re-embedded rather than only new ones.
--
-- No TRUNCATE: ingest_worker deletes and re-inserts a document's chunks inside
-- one transaction, so recall keeps serving the old vectors for a document until
-- its own re-embed commits. Idempotent to replay — ON CONFLICT DO NOTHING
-- re-queues only docs that are not already pending.

BEGIN;

INSERT INTO embedding_jobs (doc_id, status)
SELECT id, 'pending' FROM documents
ON CONFLICT (doc_id, status) DO NOTHING;

COMMIT;
