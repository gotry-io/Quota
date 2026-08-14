PRAGMA foreign_keys = ON;

ALTER TABLE usage_hourly RENAME TO usage_hourly_before_cursor;

CREATE TABLE usage_hourly (
  device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  bucket_start_utc TEXT NOT NULL,
  usage_date TEXT NOT NULL,
  usage_hour INTEGER NOT NULL CHECK (usage_hour BETWEEN 0 AND 23),
  aggregation_timezone TEXT NOT NULL,
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
  PRIMARY KEY (
    device_id, bucket_start_utc, usage_date, usage_hour,
    agent, billing_channel, channel_source, model,
    context_bucket, service_tier, speed, inference_geo
  )
);

INSERT INTO usage_hourly SELECT * FROM usage_hourly_before_cursor;
DROP TABLE usage_hourly_before_cursor;
CREATE INDEX usage_hourly_device_utc_idx ON usage_hourly(device_id, bucket_start_utc);
CREATE INDEX usage_hourly_device_date_idx ON usage_hourly(device_id, usage_date);

ALTER TABLE usage_coverage RENAME TO usage_coverage_before_cursor;

CREATE TABLE usage_coverage (
  device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  agent TEXT NOT NULL CHECK (agent IN ('codex', 'claude_code', 'grok', 'opencode', 'pi', 'cursor')),
  start_at TEXT NOT NULL,
  end_at TEXT NOT NULL,
  parser_revision TEXT NOT NULL,
  submission_id TEXT NOT NULL,
  accepted_at TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'complete' CHECK (status IN ('complete', 'partial')),
  PRIMARY KEY (device_id, agent, start_at, end_at)
);

INSERT INTO usage_coverage SELECT * FROM usage_coverage_before_cursor;
DROP TABLE usage_coverage_before_cursor;
CREATE INDEX usage_coverage_device_idx ON usage_coverage(device_id, start_at, end_at);

ALTER TABLE usage_submissions RENAME TO usage_submissions_before_cursor;

CREATE TABLE usage_submissions (
  device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  submission_id TEXT NOT NULL,
  generation INTEGER NOT NULL CHECK (generation > 0),
  sequence INTEGER NOT NULL CHECK (sequence >= 0),
  request_digest TEXT NOT NULL,
  usage_sync_revision INTEGER NOT NULL CHECK (usage_sync_revision > 0),
  agent TEXT NOT NULL CHECK (agent IN ('codex', 'claude_code', 'grok', 'opencode', 'pi', 'cursor')),
  start_at TEXT NOT NULL,
  end_at TEXT NOT NULL,
  accepted_at TEXT NOT NULL,
  write_mode TEXT CHECK (write_mode IS NULL OR write_mode = 'merge_partial'),
  multipart_batch_id TEXT,
  multipart_part_index INTEGER CHECK (multipart_part_index IS NULL OR multipart_part_index >= 0),
  multipart_part_count INTEGER CHECK (multipart_part_count IS NULL OR multipart_part_count >= 2),
  rejection_reason TEXT CHECK (
    rejection_reason IS NULL OR rejection_reason = 'duplicate_fact_identity'
  ),
  PRIMARY KEY (device_id, submission_id),
  UNIQUE (device_id, generation, sequence)
);

INSERT INTO usage_submissions SELECT * FROM usage_submissions_before_cursor;
DROP TABLE usage_submissions_before_cursor;
CREATE INDEX usage_submissions_device_idx ON usage_submissions(device_id, accepted_at);
CREATE INDEX usage_submissions_multipart_idx
  ON usage_submissions(device_id, multipart_batch_id, multipart_part_index);

ALTER TABLE usage_submission_parts RENAME TO usage_submission_parts_before_cursor;

CREATE TABLE usage_submission_parts (
  device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  batch_id TEXT NOT NULL,
  part_index INTEGER NOT NULL CHECK (part_index >= 0),
  part_count INTEGER NOT NULL CHECK (part_count >= 2 AND part_index < part_count),
  submission_id TEXT NOT NULL,
  generation INTEGER NOT NULL CHECK (generation > 0),
  sequence INTEGER NOT NULL CHECK (sequence >= 0),
  request_digest TEXT NOT NULL,
  write_mode TEXT CHECK (write_mode IS NULL OR write_mode = 'merge_partial'),
  agent TEXT NOT NULL CHECK (agent IN ('codex', 'claude_code', 'grok', 'opencode', 'pi', 'cursor')),
  start_at TEXT NOT NULL,
  end_at TEXT NOT NULL,
  parser_revision TEXT NOT NULL,
  aggregation_timezone TEXT NOT NULL,
  rows_json TEXT NOT NULL,
  accepted_at TEXT NOT NULL,
  PRIMARY KEY (device_id, batch_id, part_index),
  UNIQUE (device_id, submission_id)
);

INSERT INTO usage_submission_parts SELECT * FROM usage_submission_parts_before_cursor;
DROP TABLE usage_submission_parts_before_cursor;
CREATE INDEX usage_submission_parts_device_idx
  ON usage_submission_parts(device_id, batch_id, part_index);
