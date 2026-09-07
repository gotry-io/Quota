-- The leaderboard is a place on a page, and being on it is a separate answer from publishing
-- one: a public page says what a person ran, and a board says how that compares to everyone
-- else, which is a thing to be asked rather than assumed
-- (docs/decisions/0045-the-leaderboard-is-a-page-you-opt-into.md).
--
-- The default is 0, so every profile that already exists — and every one published without
-- touching the switch — is off the board. `enabled` still gates the read: a page taken down
-- takes its row off the board with it, and switching this off alone is how someone stays
-- published while going unlisted.
ALTER TABLE public_profiles
  ADD COLUMN on_leaderboard INTEGER NOT NULL DEFAULT 0 CHECK (on_leaderboard IN (0, 1));

-- The board reads every listed profile at once, so the listed set is what the index has to
-- answer, not one account at a time.
CREATE INDEX public_profiles_on_leaderboard
  ON public_profiles(on_leaderboard, enabled);
