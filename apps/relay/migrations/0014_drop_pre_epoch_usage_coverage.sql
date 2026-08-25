-- Coverage windows that begin before any agent this Account accepts existed were computed from
-- a missing lower bound, not scanned.  They march forward from the Unix epoch in chunks of the
-- wire's span limit and make a range look scanned that no device has ever read.
DELETE FROM usage_coverage WHERE start_at < '2020-01-01T00:00:00Z';
DELETE FROM usage_hourly WHERE bucket_start_utc < '2020-01-01T00:00:00Z';
