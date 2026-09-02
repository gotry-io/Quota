-- ADR 0030: a rotation whose successor was never presented did not happen from the client's
-- point of view. The row keeps the refresh token it replaced and when, so that token can be
-- spent once more while the successor is unspent (last_used_at = rotated_at).
ALTER TABLE sessions ADD COLUMN previous_refresh_token_hash TEXT;
ALTER TABLE sessions ADD COLUMN rotated_at TEXT;
CREATE UNIQUE INDEX sessions_previous_refresh_idx ON sessions(previous_refresh_token_hash);
