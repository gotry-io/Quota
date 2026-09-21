-- Alert policy and the monthly budget follow the Account, so they live in their own table
-- rather than columns on `accounts`: the document is one compare-and-set blob, and deleting
-- the Account deletes it with everything else
-- (docs/decisions/0061-alert-policy-and-the-budget-follow-the-account.md).
--
-- Revision 0 is not stored. It is the synthesized document a GET answers when this table has
-- no row, and the If-Match a first write presents. Live sessions gain `account:settings` so
-- nobody has to sign in again to write the document.
CREATE TABLE account_settings (
  account_id TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  revision INTEGER NOT NULL,
  settings_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

UPDATE sessions
SET scopes_json = json_insert(scopes_json, '$[#]', 'account:settings')
WHERE revoked_at IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM json_each(scopes_json) WHERE json_each.value = 'account:settings'
  );
