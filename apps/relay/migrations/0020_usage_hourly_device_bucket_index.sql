-- A local day begins at local midnight, so the UTC day at each edge of `today`, `last_7_days`,
-- and `last_30_days` can no longer be read from the daily rollup: an Account read walks a few
-- hours of `usage_hourly` per edge. The stored key leads with (device_id, agent, ...), which
-- makes that walk step over every agent to reach a run of hours. This index is the run itself.
CREATE INDEX usage_hourly_device_bucket_idx ON usage_hourly(device_id, bucket_start_utc);
