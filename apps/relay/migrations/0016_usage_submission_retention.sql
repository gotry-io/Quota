-- Hourly maintenance deletes Usage receipts older than the retry window. Without an index on
-- the column it filters, that bounded delete still scans the whole table on every run.
CREATE INDEX usage_submissions_accepted_idx ON usage_submissions(accepted_at);
