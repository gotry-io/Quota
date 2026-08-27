-- The public profile feature is removed. Its columns carry the only account data Relay ever
-- published without authentication, so they are dropped rather than left unread. The unique
-- index over the slug must go first: SQLite refuses to drop a column an index references.
DROP INDEX IF EXISTS accounts_public_profile_slug;
ALTER TABLE accounts DROP COLUMN public_profile_enabled;
ALTER TABLE accounts DROP COLUMN public_profile_slug;
