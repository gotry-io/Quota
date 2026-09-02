-- ADR 0031: the Usage fold of an Account summary, keyed by what it depends on.
CREATE TABLE account_usage_folds (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  fold_key TEXT NOT NULL,
  usage_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (account_id, fold_key)
);
CREATE INDEX account_usage_folds_created_idx ON account_usage_folds(created_at);
