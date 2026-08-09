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
