PRAGMA foreign_keys = ON;

-- Retained facts that carry no measurable usage at all cannot be produced by
-- any current collector: every scanner drops a record whose tokens, billable
-- tool requests, and source cost are all zero before it becomes a fact. Rows
-- like these are residue from the first Usage collector, which emitted a fact
-- for every parsed assistant record. The surviving example is Claude Code's
-- internal `<synthetic>` marker, normalized to the `synthetic` model and, at
-- that time, also mislabeled as the `anthropic_direct` channel. It shows up in
-- account summaries as a model with zero tokens and an unpriced row.
--
-- Replacement only rewrites the hour ranges a device re-uploads, and those
-- hours left the device's dirty set long ago, so the rows never get corrected
-- by normal synchronization. Delete them once here instead.
--
-- `requests` is deliberately not part of the predicate: a request count alone
-- is not billable usage, and it is exactly what these rows still carry.
DELETE FROM usage_hourly
WHERE input_tokens = 0
  AND cache_read_tokens = 0
  AND cache_write_5m_tokens = 0
  AND cache_write_1h_tokens = 0
  AND cache_write_inferred_tokens = 0
  AND output_tokens = 0
  AND reasoning_tokens = 0
  AND web_search_requests = 0
  AND web_fetch_requests = 0
  AND (source_cost_microusd IS NULL OR source_cost_microusd = '0');
