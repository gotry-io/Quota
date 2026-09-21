-- Quota history may follow the Account when the Account's switch is on
-- (docs/decisions/0062-quota-history-may-follow-the-account.md). Each row is one
-- downsampled bucket of one device's reading of one global-scope subscription window.
-- Storage is per device; a read merges with MAX(used_percent). Delete Device removes
-- that device's rows (a hole in the merged line is the honest result). Turning the
-- switch off deletes the Account's rows in the same write as the settings document.
-- Delete Account names the table. A row expires at `expires_at` = bucket_start +
-- span(duration_seconds) where span is min(30 d, max(48 h, 4 × duration_seconds)),
-- swept on its own 5 000-row batch rather than the shared maintenance limit.
-- The latest `duration_seconds` declared for a window rewrites every row of that
-- window. An Account that already holds 50 000 rows refuses a further upload.
--
-- Shipped Account settings rows have no history section; the default is off, so the
-- backfill is the stored document a GET already answers.
CREATE TABLE quota_history (
  device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL,
  provider TEXT NOT NULL,
  fingerprint TEXT NOT NULL,
  window_id TEXT NOT NULL,
  resets_at TEXT NOT NULL,
  bucket_start TEXT NOT NULL,
  used_percent REAL NOT NULL,
  duration_seconds INTEGER NOT NULL,
  updated_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  PRIMARY KEY (device_id, provider, fingerprint, window_id, resets_at, bucket_start)
);

CREATE INDEX quota_history_read_idx
  ON quota_history (account_id, provider, fingerprint, bucket_start);

CREATE INDEX quota_history_expires_idx
  ON quota_history (expires_at);

UPDATE account_settings
SET settings_json = json_insert(settings_json, '$.history', json('{"sync":false}'))
WHERE json_extract(settings_json, '$.history') IS NULL;
