PRAGMA defer_foreign_keys = ON;

ALTER TABLE users RENAME TO users_legacy;
ALTER TABLE pairing_sessions RENAME TO pairing_sessions_legacy;
ALTER TABLE devices RENAME TO devices_legacy;
ALTER TABLE quota_snapshots RENAME TO quota_snapshots_legacy;
ALTER TABLE auth_sessions RENAME TO auth_sessions_legacy;

CREATE TABLE controllers (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('managed', 'permanent')),
  created_at TEXT NOT NULL
);

INSERT INTO controllers (id, kind, created_at)
SELECT id, 'permanent', created_at FROM users_legacy;

CREATE TABLE pairing_sessions (
  id TEXT PRIMARY KEY,
  controller_id TEXT REFERENCES controllers(id) ON DELETE CASCADE,
  device_code_hash TEXT NOT NULL UNIQUE,
  user_code_hash TEXT NOT NULL UNIQUE,
  device_display_name TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  approved_at TEXT,
  denied_at TEXT,
  consumed_at TEXT,
  created_at TEXT NOT NULL,
  CHECK (approved_at IS NULL OR (controller_id IS NOT NULL AND denied_at IS NULL)),
  CHECK (denied_at IS NULL OR (controller_id IS NOT NULL AND approved_at IS NULL)),
  CHECK (consumed_at IS NULL OR (approved_at IS NOT NULL AND denied_at IS NULL))
);

INSERT INTO pairing_sessions
  (id, controller_id, device_code_hash, user_code_hash, device_display_name, expires_at,
   approved_at, denied_at, consumed_at, created_at)
SELECT id, owner_id, device_code_hash, user_code_hash, device_display_name, expires_at,
       approved_at, denied_at, consumed_at, created_at
FROM pairing_sessions_legacy;

CREATE TABLE devices (
  id TEXT PRIMARY KEY,
  controller_id TEXT NOT NULL REFERENCES controllers(id) ON DELETE CASCADE,
  display_name TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  pairing_session_id TEXT REFERENCES pairing_sessions(id) ON DELETE SET NULL,
  created_at TEXT NOT NULL,
  last_seen_at TEXT,
  last_sequence INTEGER NOT NULL DEFAULT -1 CHECK (last_sequence >= -1),
  revoked_at TEXT
);

INSERT INTO devices
  (id, controller_id, display_name, token_hash, pairing_session_id, created_at, last_seen_at,
   last_sequence, revoked_at)
SELECT id, owner_id, display_name, token_hash, pairing_session_id, created_at, last_seen_at,
       last_sequence, revoked_at
FROM devices_legacy;

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

INSERT INTO quota_snapshots
  (device_id, provider, account_fingerprint, sequence, captured_at, observed_at, snapshot_json,
   updated_at)
SELECT device_id, provider, account_fingerprint, sequence, captured_at, observed_at, snapshot_json,
       updated_at
FROM quota_snapshots_legacy;

CREATE TABLE controller_sessions (
  id TEXT PRIMARY KEY,
  controller_id TEXT NOT NULL REFERENCES controllers(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  scopes_json TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  revoked_at TEXT,
  created_at TEXT NOT NULL
);

INSERT INTO controller_sessions
  (id, controller_id, token_hash, scopes_json, expires_at, revoked_at, created_at)
SELECT id, owner_id, token_hash, scopes_json, expires_at, revoked_at, created_at
FROM auth_sessions_legacy;

DROP TABLE quota_snapshots_legacy;
DROP TABLE devices_legacy;
DROP TABLE pairing_sessions_legacy;
DROP TABLE auth_sessions_legacy;
DROP TABLE users_legacy;

CREATE INDEX devices_controller_id_idx ON devices(controller_id);
CREATE UNIQUE INDEX devices_pairing_session_id_idx
ON devices(pairing_session_id)
WHERE pairing_session_id IS NOT NULL;
CREATE INDEX devices_activity_idx ON devices(revoked_at, last_seen_at, created_at);
CREATE INDEX pairing_sessions_controller_id_idx ON pairing_sessions(controller_id);
CREATE INDEX pairing_sessions_expires_at_idx ON pairing_sessions(expires_at);
CREATE INDEX quota_snapshots_observed_at_idx ON quota_snapshots(observed_at);
CREATE INDEX controller_sessions_controller_id_idx ON controller_sessions(controller_id);
