PRAGMA foreign_keys = ON;

-- An hour remembers the scan behind it whether or not that scan found anything.
--
-- The version used to be a column on the fact rows, so an hour a scan emptied lost it with them:
-- the next upload of that hour found no stored version, could not tell an older scan from a newer
-- one, and let a scan that had already been replaced put its rows back. A version describes the
-- hour, not the rows inside it, so it is stored as its own row and outlives an empty scan.
CREATE TABLE usage_hour_scans (
  device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  agent TEXT NOT NULL CHECK (agent IN ('codex', 'claude_code', 'grok', 'opencode', 'pi', 'cursor')),
  bucket_start_utc TEXT NOT NULL,
  scan_version INTEGER NOT NULL CHECK (scan_version >= 0),
  PRIMARY KEY (device_id, agent, bucket_start_utc)
);

INSERT INTO usage_hour_scans (device_id, agent, bucket_start_utc, scan_version)
SELECT device_id, agent, bucket_start_utc, MAX(scan_version)
FROM usage_hourly
GROUP BY device_id, agent, bucket_start_utc;

-- Retention now sweeps both fact tables by age, and neither primary key leads with the instant
-- the sweep bounds: usage_hourly leads with the device, usage_daily with the device and date. A
-- bounded delete that has to scan the whole table to find its hundred rows gets slower exactly as
-- the table it exists to bound gets bigger.
CREATE INDEX usage_hourly_bucket_idx ON usage_hourly(bucket_start_utc);
CREATE INDEX usage_daily_date_idx ON usage_daily(utc_date);
CREATE INDEX usage_hour_scans_bucket_idx ON usage_hour_scans(bucket_start_utc);
