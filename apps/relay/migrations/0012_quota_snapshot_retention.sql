-- Retention deletes the oldest observations first, which needs the age of a reading to be
-- an index lookup rather than a scan of every account's snapshots.
CREATE INDEX IF NOT EXISTS quota_snapshots_observed_at_idx ON quota_snapshots(observed_at);
