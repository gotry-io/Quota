PRAGMA foreign_keys = ON;

-- Better Auth becomes the canonical Web identity/session layer. This is a greenfield cutover:
-- unreleased custom Web sessions and login grants are intentionally discarded.
ALTER TABLE accounts RENAME COLUMN github_subject_hash TO identity_subject;

DROP TABLE account_sessions;
CREATE TABLE account_sessions (
  id TEXT PRIMARY KEY,
  family_id TEXT NOT NULL,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  device_id TEXT REFERENCES devices(id) ON DELETE CASCADE,
  access_token_hash TEXT NOT NULL UNIQUE,
  refresh_token_hash TEXT NOT NULL UNIQUE,
  scopes_json TEXT NOT NULL,
  authenticated_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  refresh_expires_at TEXT NOT NULL,
  last_used_at TEXT NOT NULL,
  revoked_at TEXT,
  created_at TEXT NOT NULL
);

CREATE INDEX account_sessions_account_idx ON account_sessions(account_id, revoked_at, created_at);
CREATE INDEX account_sessions_family_idx ON account_sessions(family_id);
CREATE INDEX account_sessions_expiry_idx ON account_sessions(refresh_expires_at);

DROP TABLE login_grants;
CREATE TABLE login_grants (
  id TEXT PRIMARY KEY,
  grant_kind TEXT NOT NULL CHECK (grant_kind IN ('browser_pkce', 'device_code')),
  client_id TEXT NOT NULL,
  account_id TEXT REFERENCES accounts(id) ON DELETE CASCADE,
  device_id TEXT REFERENCES devices(id) ON DELETE SET NULL,
  login_token_hash TEXT UNIQUE,
  code_hash TEXT UNIQUE,
  device_code_hash TEXT UNIQUE,
  user_code_hash TEXT UNIQUE,
  installation_id_hash TEXT,
  device_display_name TEXT,
  platform TEXT,
  pkce_challenge TEXT,
  redirect_uri TEXT,
  client_state TEXT,
  completion_nonce_hash TEXT UNIQUE,
  consume_nonce_hash TEXT UNIQUE,
  expires_at TEXT NOT NULL,
  poll_interval_seconds INTEGER,
  last_polled_at TEXT,
  approved_at TEXT,
  completed_at TEXT,
  consumed_at TEXT,
  denied_at TEXT,
  created_at TEXT NOT NULL
);

CREATE INDEX login_grants_account_idx ON login_grants(account_id);
CREATE INDEX login_grants_expiry_idx ON login_grants(expires_at);

CREATE TABLE auth_users (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  email TEXT NOT NULL UNIQUE,
  emailVerified INTEGER NOT NULL,
  image TEXT,
  createdAt DATE NOT NULL,
  updatedAt DATE NOT NULL
);

-- Sessions are held in auth_session_store below. This table is retained because it is part of
-- Better Auth's stable schema, but storeSessionInDatabase is disabled and it remains empty.
CREATE TABLE auth_sessions (
  id TEXT PRIMARY KEY,
  expiresAt DATE NOT NULL,
  token TEXT NOT NULL UNIQUE,
  createdAt DATE NOT NULL,
  updatedAt DATE NOT NULL,
  ipAddress TEXT,
  userAgent TEXT,
  userId TEXT NOT NULL REFERENCES auth_users(id) ON DELETE CASCADE
);

CREATE INDEX auth_sessions_userId_idx ON auth_sessions(userId);

CREATE TABLE auth_identities (
  id TEXT PRIMARY KEY,
  accountId TEXT NOT NULL,
  providerId TEXT NOT NULL,
  userId TEXT NOT NULL REFERENCES auth_users(id) ON DELETE CASCADE,
  accessToken TEXT,
  refreshToken TEXT,
  idToken TEXT,
  accessTokenExpiresAt DATE,
  refreshTokenExpiresAt DATE,
  scope TEXT,
  password TEXT,
  createdAt DATE NOT NULL,
  updatedAt DATE NOT NULL,
  UNIQUE (providerId, accountId)
);

CREATE INDEX auth_identities_userId_idx ON auth_identities(userId);

CREATE TABLE auth_verifications (
  id TEXT PRIMARY KEY,
  identifier TEXT NOT NULL,
  value TEXT NOT NULL,
  expiresAt DATE NOT NULL,
  createdAt DATE NOT NULL,
  updatedAt DATE NOT NULL
);

CREATE INDEX auth_verifications_identifier_idx ON auth_verifications(identifier);

CREATE TABLE auth_rate_limits (
  id TEXT PRIMARY KEY,
  key TEXT NOT NULL UNIQUE,
  count INTEGER NOT NULL,
  lastRequest INTEGER NOT NULL
);

-- Better Auth's secondary-storage API keeps raw session material out of D1: keys are HMACs and
-- values are AES-GCM ciphertext bound to each key hash.
CREATE TABLE auth_session_store (
  key_hash TEXT PRIMARY KEY,
  value_ciphertext TEXT NOT NULL,
  expires_at TEXT NOT NULL
);

CREATE INDEX auth_session_store_expiry_idx ON auth_session_store(expires_at);
