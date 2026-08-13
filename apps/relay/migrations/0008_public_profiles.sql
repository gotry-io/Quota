ALTER TABLE accounts ADD COLUMN public_profile_enabled INTEGER NOT NULL DEFAULT 0
  CHECK (public_profile_enabled IN (0, 1));
ALTER TABLE accounts ADD COLUMN public_profile_slug TEXT;
CREATE UNIQUE INDEX accounts_public_profile_slug
  ON accounts(public_profile_slug)
  WHERE public_profile_slug IS NOT NULL;
