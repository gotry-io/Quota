PRAGMA foreign_keys = ON;

-- Relay writes the browser session itself now. A hand-written GitHub OAuth flow stores one row in
-- account_sessions, so the second identity store — its own users, sessions, identities,
-- verifications, encrypted session values, and rate-limit counters — has nothing left to hold.
DROP TABLE IF EXISTS auth_session_store;
DROP TABLE IF EXISTS auth_rate_limits;
DROP TABLE IF EXISTS auth_verifications;
DROP TABLE IF EXISTS auth_identities;
DROP TABLE IF EXISTS auth_sessions;
DROP TABLE IF EXISTS auth_users;

-- One table now answers for all three clients, so a row states which one it belongs to instead of
-- having it inferred from whether a Device is attached. A browser session carries no refresh token:
-- the cookie is the whole credential and it is never rotated, so refresh_token_hash is nullable and
-- refresh_expires_at repeats expires_at, which keeps one retention rule reaching every row.
-- The new table is built beside the old one because index names are database-wide: renaming the old
-- table would carry its indexes with it and collide with the ones recreated below.
CREATE TABLE account_sessions_with_client_kind (
  id TEXT PRIMARY KEY,
  family_id TEXT NOT NULL,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  device_id TEXT REFERENCES devices(id) ON DELETE CASCADE,
  client_kind TEXT NOT NULL CHECK (client_kind IN ('web', 'cli', 'ios')),
  access_token_hash TEXT NOT NULL UNIQUE,
  refresh_token_hash TEXT UNIQUE,
  scopes_json TEXT NOT NULL,
  authenticated_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  refresh_expires_at TEXT NOT NULL,
  last_used_at TEXT NOT NULL,
  revoked_at TEXT,
  created_at TEXT NOT NULL
);

-- Retained sessions were all native: a Device-bound row is QuotaBar or QuotaCLI, and a row with no
-- Device is the read-only iOS client. No browser session existed in this table to carry over.
INSERT INTO account_sessions_with_client_kind (
  id, family_id, account_id, device_id, client_kind, access_token_hash, refresh_token_hash,
  scopes_json, authenticated_at, expires_at, refresh_expires_at, last_used_at, revoked_at, created_at
)
SELECT
  id, family_id, account_id, device_id,
  CASE WHEN device_id IS NULL THEN 'ios' ELSE 'cli' END,
  access_token_hash, refresh_token_hash,
  scopes_json, authenticated_at, expires_at, refresh_expires_at, last_used_at, revoked_at, created_at
FROM account_sessions;

DROP TABLE account_sessions;
ALTER TABLE account_sessions_with_client_kind RENAME TO account_sessions;

CREATE INDEX account_sessions_account_idx ON account_sessions(account_id, revoked_at, created_at);
CREATE INDEX account_sessions_family_idx ON account_sessions(family_id);
CREATE INDEX account_sessions_expiry_idx ON account_sessions(refresh_expires_at);
