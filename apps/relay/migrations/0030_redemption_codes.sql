CREATE TABLE redemption_codes (
  code TEXT PRIMARY KEY,
  campaign TEXT NOT NULL,
  grant_duration TEXT NOT NULL CHECK (grant_duration IN ('weekly','monthly','two_month','three_month','six_month','yearly','lifetime')),
  max_redemptions INTEGER NOT NULL CHECK (max_redemptions > 0),
  redeemed_count INTEGER NOT NULL DEFAULT 0,
  expires_at TEXT,
  note TEXT,
  created_at TEXT NOT NULL
);
CREATE TABLE code_redemptions (
  code TEXT NOT NULL REFERENCES redemption_codes(code) ON DELETE CASCADE,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  redeemed_at TEXT NOT NULL,
  PRIMARY KEY (code, account_id)
);
CREATE INDEX code_redemptions_account_idx ON code_redemptions(account_id);
