PRAGMA foreign_keys = ON;

CREATE TABLE device_health (
  device_id TEXT PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
  device_generation INTEGER NOT NULL CHECK (device_generation > 0),
  schema_version INTEGER NOT NULL CHECK (schema_version = 1),
  client_product TEXT NOT NULL CHECK (client_product IN ('quotabar', 'quotacli')),
  client_version TEXT NOT NULL CHECK (length(client_version) BETWEEN 1 AND 32),
  platform TEXT NOT NULL CHECK (platform IN ('macos', 'linux', 'windows')),
  observed_at TEXT NOT NULL,
  refresh_revision INTEGER NOT NULL CHECK (refresh_revision >= 0),
  received_at TEXT NOT NULL,
  fresh_until TEXT NOT NULL,
  last_completed_refresh_at TEXT,
  last_successful_account_sync_at TEXT,
  operation TEXT NOT NULL CHECK (operation IN ('healthy', 'degraded', 'blocked')),
  data_state TEXT NOT NULL CHECK (data_state IN ('current', 'stale', 'partial', 'empty', 'unknown')),
  attention TEXT NOT NULL CHECK (attention IN ('none', 'automatic', 'optional', 'required')),
  top_code TEXT CHECK (top_code IS NULL OR top_code IN (
    'refresh_failed', 'quota_collection_failed', 'usage_scan_partial',
    'usage_upload_failed', 'account_sync_failed', 'pricing_refresh_failed',
    'process_interrupted', 'local_state_invalid'
  )),
  consecutive_failures INTEGER NOT NULL CHECK (consecutive_failures BETWEEN 0 AND 1000),
  usage_upload_enabled INTEGER NOT NULL CHECK (usage_upload_enabled IN (0, 1))
);

CREATE INDEX device_health_received_idx ON device_health(received_at DESC, device_id);
