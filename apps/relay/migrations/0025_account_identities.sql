PRAGMA foreign_keys = ON;

-- ADR 0032: an Account owns its identities. GitHub stops being the Account.
--
-- `accounts.identity_subject` was the HMAC of a GitHub numeric id and also the Account id, so an
-- Account could only ever be reached one way. Identities move to their own table, keyed by the
-- channel that proved them, and the Account id becomes an opaque id of its own.
--
-- Quota has no released Relay users, so this is a cutover rather than a backfill: every Account and
-- everything hanging off one is deleted, and the next sign-in creates a new Account. Rows are
-- removed before `accounts` is dropped so no foreign key is left pointing at a table that is about
-- to be rebuilt.
DELETE FROM usage_daily;
DELETE FROM usage_hourly;
DELETE FROM usage_hour_scans;
DELETE FROM quota_snapshots;
DELETE FROM account_usage_folds;
DELETE FROM sessions;
DELETE FROM login_grants;
DELETE FROM devices;
DELETE FROM accounts;

-- `identity_subject` is UNIQUE, and SQLite will not drop an indexed column, so the table is rebuilt
-- rather than altered.
DROP TABLE accounts;
CREATE TABLE accounts (
  id TEXT PRIMARY KEY,
  display_label TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- One row per proven identity. `subject` is always an HMAC under `IDENTITY_SUBJECT_KEY` — never a
-- GitHub id, an Apple `sub`, or an address as the provider stated it. `(provider, subject)` is the
-- primary key because that pair is what a sign-in arrives holding; `(account_id, provider)` is
-- unique because an Account is reached through a channel at most once, and its leftmost column is
-- what lists an Account's identities.
CREATE TABLE account_identities (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  provider TEXT NOT NULL CHECK (provider IN ('github', 'apple', 'email')),
  subject TEXT NOT NULL,
  label TEXT,
  created_at TEXT NOT NULL,
  PRIMARY KEY (provider, subject),
  UNIQUE (account_id, provider)
);
