PRAGMA foreign_keys = ON;

-- An hour of Usage is now replaced whole, by version, so a stored row is identified by what it
-- measures and the hour it was measured in. The local date, the local hour, and the timezone that
-- produced them are gone: they made one measurement look like two rows whenever a device moved,
-- and no read has ever asked a stored row which local day it fell on.
ALTER TABLE usage_hourly RENAME TO usage_hourly_before_scan_versions;

CREATE TABLE usage_hourly (
  device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  agent TEXT NOT NULL CHECK (agent IN ('codex', 'claude_code', 'grok', 'opencode', 'pi', 'cursor')),
  bucket_start_utc TEXT NOT NULL,
  scan_version INTEGER NOT NULL CHECK (scan_version >= 0),
  partial INTEGER NOT NULL CHECK (partial IN (0, 1)),
  billing_channel TEXT NOT NULL,
  channel_source TEXT NOT NULL CHECK (channel_source IN ('explicit', 'agent_default', 'unknown')),
  model TEXT NOT NULL,
  context_bucket TEXT NOT NULL,
  service_tier TEXT NOT NULL,
  speed TEXT NOT NULL,
  inference_geo TEXT NOT NULL,
  input_tokens INTEGER NOT NULL CHECK (input_tokens >= 0),
  cache_read_tokens INTEGER NOT NULL CHECK (cache_read_tokens >= 0),
  cache_write_5m_tokens INTEGER NOT NULL CHECK (cache_write_5m_tokens >= 0),
  cache_write_1h_tokens INTEGER NOT NULL CHECK (cache_write_1h_tokens >= 0),
  cache_write_inferred_tokens INTEGER NOT NULL CHECK (cache_write_inferred_tokens >= 0),
  output_tokens INTEGER NOT NULL CHECK (output_tokens >= 0),
  reasoning_tokens INTEGER NOT NULL CHECK (reasoning_tokens >= 0),
  requests INTEGER NOT NULL CHECK (requests >= 0),
  web_search_requests INTEGER NOT NULL CHECK (web_search_requests >= 0),
  web_fetch_requests INTEGER NOT NULL CHECK (web_fetch_requests >= 0),
  source_cost_microusd TEXT,
  source_cost_covered_requests INTEGER NOT NULL CHECK (source_cost_covered_requests >= 0),
  PRIMARY KEY (
    device_id, agent, bucket_start_utc, billing_channel, channel_source, model,
    context_bucket, service_tier, speed, inference_geo
  )
);

-- Retained facts arrive at version 0, which is older than any scan a client can report, so the
-- first upload of an hour replaces what is here. Rows that differed only by the timezone they were
-- projected through collapse into one, so their counts are added rather than picked.
INSERT INTO usage_hourly (
  device_id, agent, bucket_start_utc, scan_version, partial,
  billing_channel, channel_source, model, context_bucket, service_tier, speed, inference_geo,
  input_tokens, cache_read_tokens, cache_write_5m_tokens, cache_write_1h_tokens,
  cache_write_inferred_tokens, output_tokens, reasoning_tokens, requests,
  web_search_requests, web_fetch_requests, source_cost_microusd, source_cost_covered_requests
)
SELECT
  device_id, agent, bucket_start_utc, 0, 0,
  billing_channel, channel_source, model, context_bucket, service_tier, speed, inference_geo,
  SUM(input_tokens), SUM(cache_read_tokens), SUM(cache_write_5m_tokens),
  SUM(cache_write_1h_tokens), SUM(cache_write_inferred_tokens), SUM(output_tokens),
  SUM(reasoning_tokens), SUM(requests), SUM(web_search_requests), SUM(web_fetch_requests),
  CASE
    WHEN SUM(source_cost_covered_requests) > 0
      THEN CAST(SUM(CAST(COALESCE(source_cost_microusd, '0') AS INTEGER)) AS TEXT)
    ELSE NULL
  END,
  SUM(source_cost_covered_requests)
FROM usage_hourly_before_scan_versions
GROUP BY
  device_id, agent, bucket_start_utc, billing_channel, channel_source, model,
  context_bucket, service_tier, speed, inference_geo;

DROP TABLE usage_hourly_before_scan_versions;

-- Every managed read folds days, not hours, so the days are kept folded. The upload that changes
-- an hour rewrites the UTC dates it touched in the same batch, which is what lets a read stay off
-- usage_hourly entirely. The key leads with (device_id, utc_date) because that is how an Account
-- reaches these rows: through the devices it owns, over a range of days.
CREATE TABLE usage_daily (
  device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  utc_date TEXT NOT NULL,
  agent TEXT NOT NULL CHECK (agent IN ('codex', 'claude_code', 'grok', 'opencode', 'pi', 'cursor')),
  billing_channel TEXT NOT NULL,
  channel_source TEXT NOT NULL CHECK (channel_source IN ('explicit', 'agent_default', 'unknown')),
  model TEXT NOT NULL,
  context_bucket TEXT NOT NULL,
  service_tier TEXT NOT NULL,
  speed TEXT NOT NULL,
  inference_geo TEXT NOT NULL,
  input_tokens INTEGER NOT NULL CHECK (input_tokens >= 0),
  cache_read_tokens INTEGER NOT NULL CHECK (cache_read_tokens >= 0),
  cache_write_5m_tokens INTEGER NOT NULL CHECK (cache_write_5m_tokens >= 0),
  cache_write_1h_tokens INTEGER NOT NULL CHECK (cache_write_1h_tokens >= 0),
  cache_write_inferred_tokens INTEGER NOT NULL CHECK (cache_write_inferred_tokens >= 0),
  output_tokens INTEGER NOT NULL CHECK (output_tokens >= 0),
  reasoning_tokens INTEGER NOT NULL CHECK (reasoning_tokens >= 0),
  requests INTEGER NOT NULL CHECK (requests >= 0),
  web_search_requests INTEGER NOT NULL CHECK (web_search_requests >= 0),
  web_fetch_requests INTEGER NOT NULL CHECK (web_fetch_requests >= 0),
  source_cost_microusd TEXT,
  source_cost_covered_requests INTEGER NOT NULL CHECK (source_cost_covered_requests >= 0),
  partial_hours INTEGER NOT NULL CHECK (partial_hours >= 0),
  PRIMARY KEY (
    device_id, utc_date, agent, billing_channel, channel_source, model,
    context_bucket, service_tier, speed, inference_geo
  )
);

INSERT INTO usage_daily (
  device_id, utc_date, agent, billing_channel, channel_source, model,
  context_bucket, service_tier, speed, inference_geo,
  input_tokens, cache_read_tokens, cache_write_5m_tokens, cache_write_1h_tokens,
  cache_write_inferred_tokens, output_tokens, reasoning_tokens, requests,
  web_search_requests, web_fetch_requests, source_cost_microusd, source_cost_covered_requests,
  partial_hours
)
SELECT
  device_id, substr(bucket_start_utc, 1, 10), agent, billing_channel, channel_source, model,
  context_bucket, service_tier, speed, inference_geo,
  SUM(input_tokens), SUM(cache_read_tokens), SUM(cache_write_5m_tokens),
  SUM(cache_write_1h_tokens), SUM(cache_write_inferred_tokens), SUM(output_tokens),
  SUM(reasoning_tokens), SUM(requests), SUM(web_search_requests), SUM(web_fetch_requests),
  CASE
    WHEN SUM(source_cost_covered_requests) > 0
      THEN CAST(SUM(CAST(COALESCE(source_cost_microusd, '0') AS INTEGER)) AS TEXT)
    ELSE NULL
  END,
  SUM(source_cost_covered_requests),
  SUM(partial)
FROM usage_hourly
GROUP BY
  device_id, substr(bucket_start_utc, 1, 10), agent, billing_channel, channel_source, model,
  context_bucket, service_tier, speed, inference_geo;

-- Coverage windows, submission receipts, and multipart staging all existed to make a sequence of
-- appends idempotent. An hour that carries the version of the scan behind it is idempotent on its
-- own: re-sending it changes nothing, and there is no order to reconstruct.
DROP TABLE IF EXISTS usage_submission_parts;
DROP TABLE IF EXISTS usage_submissions;
DROP TABLE IF EXISTS usage_coverage;

-- The sequences those tables were checked against go with them. A snapshot is placed by
-- (provider, fingerprint) and ordered by the instant it was observed, so the digest that
-- recognized a re-sent envelope has nothing left to recognize either.
ALTER TABLE devices DROP COLUMN last_sequence;
ALTER TABLE devices DROP COLUMN last_usage_sequence;
ALTER TABLE devices DROP COLUMN last_snapshot_digest;
ALTER TABLE quota_snapshots DROP COLUMN sequence;
ALTER TABLE quota_snapshots DROP COLUMN captured_at;
