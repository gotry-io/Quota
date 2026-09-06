-- A public profile is the one thing an Account may publish without a session, so it is its own
-- table rather than columns on `accounts`: what is readable anonymously is then a table name
-- rather than a field list someone has to remember not to widen
-- (docs/decisions/0037-a-public-profile-shows-usage-not-quota.md).
--
-- The handle is the page's whole address. `COLLATE NOCASE` on the unique index is what makes
-- two handles differing only in case one page rather than two, and the same collation answers
-- the anonymous lookup, so the index serves the read it exists for.
CREATE TABLE public_profiles (
  account_id TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  handle TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 0 CHECK (enabled IN (0, 1)),
  show_models INTEGER NOT NULL DEFAULT 1 CHECK (show_models IN (0, 1)),
  show_cost INTEGER NOT NULL DEFAULT 0 CHECK (show_cost IN (0, 1)),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE UNIQUE INDEX public_profiles_handle ON public_profiles(handle COLLATE NOCASE);
