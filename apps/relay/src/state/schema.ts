export const SQLITE_SCHEMA = `
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS owners (
  id TEXT PRIMARY KEY,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS pairing_sessions (
  id TEXT PRIMARY KEY,
  owner_id TEXT REFERENCES owners(id) ON DELETE CASCADE,
  device_code_hash TEXT NOT NULL UNIQUE,
  user_code_hash TEXT NOT NULL UNIQUE,
  device_display_name TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  approved_at TEXT,
  denied_at TEXT,
  consumed_at TEXT,
  created_at TEXT NOT NULL,
  CHECK (approved_at IS NULL OR (owner_id IS NOT NULL AND denied_at IS NULL)),
  CHECK (denied_at IS NULL OR (owner_id IS NOT NULL AND approved_at IS NULL)),
  CHECK (consumed_at IS NULL OR (approved_at IS NOT NULL AND denied_at IS NULL))
);

CREATE INDEX IF NOT EXISTS pairing_sessions_owner_id_idx ON pairing_sessions(owner_id);
CREATE INDEX IF NOT EXISTS pairing_sessions_expires_at_idx ON pairing_sessions(expires_at);

CREATE TABLE IF NOT EXISTS devices (
  id TEXT PRIMARY KEY,
  owner_id TEXT NOT NULL REFERENCES owners(id) ON DELETE CASCADE,
  display_name TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  pairing_session_id TEXT REFERENCES pairing_sessions(id) ON DELETE SET NULL,
  created_at TEXT NOT NULL,
  last_seen_at TEXT,
  last_sequence INTEGER NOT NULL DEFAULT -1 CHECK (last_sequence >= -1),
  revoked_at TEXT
);

CREATE INDEX IF NOT EXISTS devices_owner_id_idx ON devices(owner_id);
CREATE UNIQUE INDEX IF NOT EXISTS devices_pairing_session_id_idx
ON devices(pairing_session_id)
WHERE pairing_session_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS devices_activity_idx ON devices(revoked_at, last_seen_at, created_at);

CREATE TABLE IF NOT EXISTS quota_snapshots (
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

CREATE INDEX IF NOT EXISTS quota_snapshots_observed_at_idx ON quota_snapshots(observed_at);

CREATE TABLE IF NOT EXISTS owner_sessions (
  id TEXT PRIMARY KEY,
  owner_id TEXT NOT NULL REFERENCES owners(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  scopes_json TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  revoked_at TEXT,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS owner_sessions_owner_id_idx ON owner_sessions(owner_id);

CREATE TABLE IF NOT EXISTS rate_limit_counters (
  key_hash TEXT NOT NULL,
  window_started_at TEXT NOT NULL,
  window_expires_at TEXT NOT NULL,
  request_count INTEGER NOT NULL CHECK (request_count >= 1),
  PRIMARY KEY (key_hash, window_started_at)
);

CREATE INDEX IF NOT EXISTS rate_limit_counters_expires_at_idx
ON rate_limit_counters(window_expires_at);
`;

export const SQLITE_SCHEMA_VERSION = 2;

export const SQLITE_MIGRATION_0002 = `
ALTER TABLE quota_snapshots RENAME TO quota_snapshots_v1;

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

INSERT INTO quota_snapshots (
  device_id,
  provider,
  account_fingerprint,
  sequence,
  captured_at,
  observed_at,
  snapshot_json,
  updated_at
)
SELECT
  device_id,
  provider,
  account_fingerprint,
  sequence,
  captured_at,
  observed_at,
  snapshot_json,
  updated_at
FROM quota_snapshots_v1;

DROP TABLE quota_snapshots_v1;

CREATE INDEX quota_snapshots_observed_at_idx ON quota_snapshots(observed_at);
`;
