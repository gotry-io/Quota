-- ADR 0059: the leaderboard is retired. The opt-in column and the index that served the board
-- are the only store the board used. A published page is unchanged: a person who had opted in
-- simply stops appearing anywhere.
--
-- The index must go first: SQLite refuses to drop a column an index references
-- (apps/relay/migrations/0015_drop_public_profiles.sql).
DROP INDEX IF EXISTS public_profiles_on_leaderboard;
ALTER TABLE public_profiles DROP COLUMN on_leaderboard;
