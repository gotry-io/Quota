PRAGMA foreign_keys = ON;

-- One-time email sign-in challenges. The address and the token are stored only as hashes;
-- the token in the mailed link is the credential, so a row that outlives its fifteen minutes
-- is swept with the other expired grants rather than kept for reuse.
CREATE TABLE email_challenges (
  id TEXT PRIMARY KEY,
  email_hash TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  intent_json TEXT NOT NULL,
  return_to TEXT NOT NULL,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  consumed_at TEXT
);
