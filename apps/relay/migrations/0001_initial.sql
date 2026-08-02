PRAGMA foreign_keys = ON;

CREATE TABLE users (
  id TEXT PRIMARY KEY,
  external_subject TEXT UNIQUE,
  created_at TEXT NOT NULL
);

CREATE TABLE devices (
  id TEXT PRIMARY KEY,
  owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  display_name TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL,
  last_seen_at TEXT,
  last_sequence INTEGER NOT NULL DEFAULT -1 CHECK (last_sequence >= -1),
  revoked_at TEXT
);

CREATE INDEX devices_owner_id_idx ON devices(owner_id);

CREATE TABLE pairing_sessions (
  id TEXT PRIMARY KEY,
  owner_id TEXT REFERENCES users(id) ON DELETE CASCADE,
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

CREATE INDEX pairing_sessions_owner_id_idx ON pairing_sessions(owner_id);
CREATE INDEX pairing_sessions_expires_at_idx ON pairing_sessions(expires_at);

CREATE TABLE quota_snapshots (
  device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  provider TEXT NOT NULL CHECK (provider IN ('codex', 'claude', 'grok')),
  account_fingerprint TEXT NOT NULL,
  sequence INTEGER NOT NULL CHECK (sequence >= 0),
  captured_at TEXT NOT NULL,
  observed_at TEXT NOT NULL,
  snapshot_json TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (device_id, provider, account_fingerprint)
);

CREATE INDEX quota_snapshots_observed_at_idx ON quota_snapshots(observed_at);

CREATE TABLE auth_sessions (
  id TEXT PRIMARY KEY,
  owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  expires_at TEXT NOT NULL,
  revoked_at TEXT,
  created_at TEXT NOT NULL
);

CREATE INDEX auth_sessions_owner_id_idx ON auth_sessions(owner_id);
