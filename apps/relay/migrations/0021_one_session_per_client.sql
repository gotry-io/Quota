PRAGMA foreign_keys = ON;

-- One session table, one token per client, and no Device Authorization Grant.
--
-- A collection login used to open two families in two tables: an account_sessions row that could
-- read the Account and a device_sessions row that could write the Device. Every rule about a
-- session was then written twice — two authorizations, two rotations, two revocations, two
-- retention sweeps — and the pair had to be kept consistent by hand. One row carries both scopes.
--
-- The new table is built beside the old ones because index names are database-wide: renaming a
-- table carries its indexes with it and would collide with the ones recreated below.
CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  family_id TEXT NOT NULL,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  device_id TEXT REFERENCES devices(id) ON DELETE CASCADE,
  -- Set together with device_id or not at all: a session names the Device it writes at the
  -- generation that Device had when the session opened, and Delete Device moves the Device past it.
  device_generation INTEGER CHECK (device_generation IS NULL OR device_generation > 0),
  client_kind TEXT NOT NULL CHECK (client_kind IN ('web', 'quotabar', 'ios')),
  access_token_hash TEXT NOT NULL UNIQUE,
  -- A browser session carries no refresh token: the cookie is the whole credential and it is
  -- never rotated, so this is null for `web` and refresh_expires_at repeats expires_at.
  refresh_token_hash TEXT UNIQUE,
  scopes_json TEXT NOT NULL,
  authenticated_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  refresh_expires_at TEXT NOT NULL,
  last_used_at TEXT NOT NULL,
  revoked_at TEXT,
  created_at TEXT NOT NULL,
  CHECK ((device_id IS NULL) = (device_generation IS NULL))
);

-- A collection family is carried over as its device half, which is the half that holds the Device
-- and its generation, and it gains the account read its account half used to hold. The account
-- half is dropped: keeping it would leave two live tokens for one login, which is the thing this
-- migration exists to end. `authenticated_at` comes from that dropped row, because a device
-- session never recorded when the person behind it proved who they were.
INSERT INTO sessions (
  id, family_id, account_id, device_id, device_generation, client_kind,
  access_token_hash, refresh_token_hash, scopes_json,
  authenticated_at, expires_at, refresh_expires_at, last_used_at, revoked_at, created_at
)
SELECT
  device_rows.id, device_rows.family_id, devices.account_id,
  device_rows.device_id, device_rows.device_generation, 'quotabar',
  device_rows.access_token_hash, device_rows.refresh_token_hash,
  '["account:read","device:write"]',
  COALESCE(
    (SELECT account_rows.authenticated_at FROM account_sessions AS account_rows
     WHERE account_rows.family_id = device_rows.family_id LIMIT 1),
    device_rows.created_at
  ),
  device_rows.expires_at, device_rows.refresh_expires_at, device_rows.last_used_at,
  device_rows.revoked_at, device_rows.created_at
FROM device_sessions AS device_rows
INNER JOIN devices ON devices.id = device_rows.device_id;

-- The browser keeps everything it had, and the read-only viewer keeps the one thing it does.
-- Ending a session is no longer a scope: holding the refresh token is the proof.
INSERT INTO sessions (
  id, family_id, account_id, device_id, device_generation, client_kind,
  access_token_hash, refresh_token_hash, scopes_json,
  authenticated_at, expires_at, refresh_expires_at, last_used_at, revoked_at, created_at
)
SELECT
  id, family_id, account_id, NULL, NULL, client_kind,
  access_token_hash, refresh_token_hash,
  CASE client_kind
    WHEN 'web' THEN '["account:read","account:manage"]'
    ELSE '["account:read"]'
  END,
  authenticated_at, expires_at, refresh_expires_at, last_used_at, revoked_at, created_at
FROM account_sessions
WHERE client_kind IN ('web', 'ios');

DROP TABLE device_sessions;
DROP TABLE account_sessions;

CREATE INDEX sessions_account_idx ON sessions(account_id, revoked_at, created_at);
CREATE INDEX sessions_family_idx ON sessions(family_id);
CREATE INDEX sessions_expiry_idx ON sessions(refresh_expires_at);
CREATE INDEX sessions_device_idx ON sessions(device_id, revoked_at, created_at);

-- Authorization Code with PKCE over a loopback callback is the only grant left, so a login grant
-- is one shape. The device code, the human-readable user code, the polling state behind them, and
-- the device profile a headless client had to state up front are all gone; so is the grant kind
-- that told them apart, and the approve/deny decision only the second screen could make. A
-- browser grant is completed or it is not.
CREATE TABLE login_grants_browser_only (
  id TEXT PRIMARY KEY,
  client_id TEXT NOT NULL,
  account_id TEXT REFERENCES accounts(id) ON DELETE CASCADE,
  device_id TEXT REFERENCES devices(id) ON DELETE SET NULL,
  login_token_hash TEXT UNIQUE,
  code_hash TEXT UNIQUE,
  pkce_challenge TEXT,
  redirect_uri TEXT,
  client_state TEXT,
  completion_nonce_hash TEXT UNIQUE,
  consume_nonce_hash TEXT UNIQUE,
  expires_at TEXT NOT NULL,
  completed_at TEXT,
  consumed_at TEXT,
  created_at TEXT NOT NULL
);

INSERT INTO login_grants_browser_only (
  id, client_id, account_id, device_id, login_token_hash, code_hash, pkce_challenge,
  redirect_uri, client_state, completion_nonce_hash, consume_nonce_hash,
  expires_at, completed_at, consumed_at, created_at
)
SELECT
  id, client_id, account_id, device_id, login_token_hash, code_hash, pkce_challenge,
  redirect_uri, client_state, completion_nonce_hash, consume_nonce_hash,
  expires_at, completed_at, consumed_at, created_at
FROM login_grants
WHERE grant_kind = 'browser_pkce';

DROP TABLE login_grants;
ALTER TABLE login_grants_browser_only RENAME TO login_grants;

CREATE INDEX login_grants_account_idx ON login_grants(account_id);
CREATE INDEX login_grants_expiry_idx ON login_grants(expires_at);

-- QuotaBar is the only client that registers a Device, so `macos` is the only platform one can
-- report and the only member the contract still names. A row left by a client this deployment no
-- longer serves can never be corrected by a device sync, because that client can no longer sign
-- in; naming it as what every remaining Device is keeps the Account readable and the row
-- deletable.
UPDATE devices SET platform = 'macos' WHERE platform IS NULL OR platform <> 'macos';

-- The `quotabar` client id replaces `quotacli`: the shared service is bundled inside QuotaBar and
-- is no longer the engine behind a command by that name.
UPDATE login_grants SET client_id = 'quotabar' WHERE client_id = 'quotacli';
