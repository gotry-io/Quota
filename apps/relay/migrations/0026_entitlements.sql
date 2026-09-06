-- ADR 0033: paid-sync entitlement is read from RevenueCat, not from a store receipt.
CREATE TABLE entitlements (
  account_id TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  status TEXT NOT NULL CHECK (status IN ('active', 'grace', 'expired', 'none')),
  product_id TEXT,
  store TEXT,
  expires_at TEXT,
  will_renew INTEGER NOT NULL CHECK (will_renew IN (0, 1)),
  source TEXT NOT NULL CHECK (source IN ('webhook', 'rest')),
  last_event_id TEXT,
  updated_at TEXT NOT NULL
);

-- Events for unknown app_user_id values are stored too, so this table does not
-- reference accounts. Duplicate deliveries collide on id and are ignored.
CREATE TABLE entitlement_events (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  type TEXT NOT NULL,
  received_at TEXT NOT NULL,
  payload_json TEXT NOT NULL
);

CREATE INDEX entitlement_events_account_idx ON entitlement_events(account_id);
