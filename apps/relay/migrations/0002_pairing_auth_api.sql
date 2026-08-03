ALTER TABLE devices
ADD COLUMN pairing_session_id TEXT REFERENCES pairing_sessions(id) ON DELETE SET NULL;

CREATE UNIQUE INDEX devices_pairing_session_id_idx
ON devices(pairing_session_id)
WHERE pairing_session_id IS NOT NULL;

ALTER TABLE auth_sessions ADD COLUMN scopes_json TEXT NOT NULL DEFAULT '[]';

CREATE TABLE rate_limit_counters (
  key_hash TEXT NOT NULL,
  window_started_at TEXT NOT NULL,
  window_expires_at TEXT NOT NULL,
  request_count INTEGER NOT NULL CHECK (request_count >= 1),
  PRIMARY KEY (key_hash, window_started_at)
);

CREATE INDEX rate_limit_counters_expires_at_idx ON rate_limit_counters(window_expires_at);
