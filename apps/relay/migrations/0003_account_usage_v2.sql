PRAGMA foreign_keys = ON;

-- Account v2 is an intentional greenfield cutover. No owner, pairing, token, or snapshot row is
-- copied into the account schema.
DROP TABLE IF EXISTS quota_snapshots;
DROP TABLE IF EXISTS owner_sessions;
DROP TABLE IF EXISTS devices;
DROP TABLE IF EXISTS pairing_sessions;
DROP TABLE IF EXISTS owners;
DROP TABLE IF EXISTS rate_limit_counters;

CREATE TABLE accounts (
  id TEXT PRIMARY KEY,
  github_subject_hash TEXT NOT NULL UNIQUE,
  display_label TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE devices (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  installation_id_hash TEXT NOT NULL,
  display_name TEXT,
  platform TEXT,
  generation INTEGER NOT NULL DEFAULT 1 CHECK (generation > 0),
  last_sequence INTEGER NOT NULL DEFAULT -1 CHECK (last_sequence >= -1),
  last_snapshot_digest TEXT,
  last_usage_sequence INTEGER NOT NULL DEFAULT -1 CHECK (last_usage_sequence >= -1),
  usage_sync_revision INTEGER NOT NULL DEFAULT 0 CHECK (usage_sync_revision >= 0),
  created_at TEXT NOT NULL,
  last_login_at TEXT NOT NULL,
  last_seen_at TEXT,
  signed_out_at TEXT,
  deleted_at TEXT,
  deleted_before TEXT,
  UNIQUE (account_id, installation_id_hash)
);

CREATE INDEX devices_account_visible_idx ON devices(account_id, deleted_at, created_at);

CREATE TABLE account_sessions (
  id TEXT PRIMARY KEY,
  family_id TEXT NOT NULL,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  device_id TEXT REFERENCES devices(id) ON DELETE CASCADE,
  access_token_hash TEXT NOT NULL UNIQUE,
  refresh_token_hash TEXT NOT NULL UNIQUE,
  client_kind TEXT NOT NULL CHECK (client_kind IN ('web', 'cli')),
  scopes_json TEXT NOT NULL,
  csrf_token_hash TEXT,
  authenticated_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  refresh_expires_at TEXT NOT NULL,
  last_used_at TEXT NOT NULL,
  revoked_at TEXT,
  created_at TEXT NOT NULL
);

CREATE INDEX account_sessions_account_idx ON account_sessions(account_id, revoked_at, created_at);
CREATE INDEX account_sessions_family_idx ON account_sessions(family_id);
CREATE INDEX account_sessions_expiry_idx ON account_sessions(refresh_expires_at);

CREATE TABLE device_sessions (
  id TEXT PRIMARY KEY,
  family_id TEXT NOT NULL,
  device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  device_generation INTEGER NOT NULL CHECK (device_generation > 0),
  access_token_hash TEXT NOT NULL UNIQUE,
  refresh_token_hash TEXT NOT NULL UNIQUE,
  scopes_json TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  refresh_expires_at TEXT NOT NULL,
  last_used_at TEXT NOT NULL,
  revoked_at TEXT,
  created_at TEXT NOT NULL
);

CREATE INDEX device_sessions_device_idx ON device_sessions(device_id, revoked_at, created_at);
CREATE INDEX device_sessions_family_idx ON device_sessions(family_id);
CREATE INDEX device_sessions_expiry_idx ON device_sessions(refresh_expires_at);

CREATE TABLE login_grants (
  id TEXT PRIMARY KEY,
  grant_kind TEXT NOT NULL CHECK (grant_kind IN ('web', 'browser_pkce', 'device_code')),
  client_id TEXT NOT NULL,
  account_id TEXT REFERENCES accounts(id) ON DELETE CASCADE,
  device_id TEXT REFERENCES devices(id) ON DELETE SET NULL,
  provider_state_hash TEXT UNIQUE,
  web_login_nonce_hash TEXT UNIQUE,
  code_hash TEXT UNIQUE,
  device_code_hash TEXT UNIQUE,
  user_code_hash TEXT UNIQUE,
  installation_id_hash TEXT,
  device_display_name TEXT,
  platform TEXT,
  pkce_challenge TEXT,
  redirect_uri TEXT,
  completion_nonce_hash TEXT UNIQUE,
  consume_nonce_hash TEXT UNIQUE,
  expires_at TEXT NOT NULL,
  poll_interval_seconds INTEGER,
  last_polled_at TEXT,
  approved_at TEXT,
  completed_at TEXT,
  consumed_at TEXT,
  denied_at TEXT,
  created_at TEXT NOT NULL
);

CREATE INDEX login_grants_account_idx ON login_grants(account_id);
CREATE INDEX login_grants_expiry_idx ON login_grants(expires_at);

CREATE TABLE quota_snapshots (
  device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  provider TEXT NOT NULL,
  account_fingerprint TEXT NOT NULL,
  sequence INTEGER NOT NULL CHECK (sequence >= 0),
  captured_at TEXT NOT NULL,
  observed_at TEXT NOT NULL,
  snapshot_json TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (device_id, provider, account_fingerprint)
);

CREATE INDEX quota_snapshots_device_idx ON quota_snapshots(device_id, updated_at);

CREATE TABLE usage_hourly (
  device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  bucket_start_utc TEXT NOT NULL,
  usage_date TEXT NOT NULL,
  usage_hour INTEGER NOT NULL CHECK (usage_hour BETWEEN 0 AND 23),
  aggregation_timezone TEXT NOT NULL,
  agent TEXT NOT NULL CHECK (agent IN ('codex', 'claude_code')),
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

CREATE INDEX usage_hourly_device_utc_idx ON usage_hourly(device_id, bucket_start_utc);
CREATE INDEX usage_hourly_device_date_idx ON usage_hourly(device_id, usage_date);

CREATE TABLE usage_coverage (
  device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  agent TEXT NOT NULL CHECK (agent IN ('codex', 'claude_code')),
  start_at TEXT NOT NULL,
  end_at TEXT NOT NULL,
  parser_revision TEXT NOT NULL,
  submission_id TEXT NOT NULL,
  accepted_at TEXT NOT NULL,
  PRIMARY KEY (device_id, agent, start_at, end_at)
);

CREATE INDEX usage_coverage_device_idx ON usage_coverage(device_id, start_at, end_at);

CREATE TABLE usage_submissions (
  device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  submission_id TEXT NOT NULL,
  generation INTEGER NOT NULL CHECK (generation > 0),
  sequence INTEGER NOT NULL CHECK (sequence >= 0),
  request_digest TEXT NOT NULL,
  usage_sync_revision INTEGER NOT NULL CHECK (usage_sync_revision > 0),
  agent TEXT NOT NULL CHECK (agent IN ('codex', 'claude_code')),
  start_at TEXT NOT NULL,
  end_at TEXT NOT NULL,
  accepted_at TEXT NOT NULL,
  PRIMARY KEY (device_id, submission_id),
  UNIQUE (device_id, generation, sequence)
);

CREATE INDEX usage_submissions_device_idx ON usage_submissions(device_id, accepted_at);

CREATE TABLE rate_limit_counters (
  key_hash TEXT NOT NULL,
  window_started_at TEXT NOT NULL,
  window_expires_at TEXT NOT NULL,
  request_count INTEGER NOT NULL CHECK (request_count >= 1),
  PRIMARY KEY (key_hash, window_started_at)
);

CREATE INDEX rate_limit_counters_expires_at_idx ON rate_limit_counters(window_expires_at);
