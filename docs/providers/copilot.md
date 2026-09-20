# GitHub Copilot

Catalog id `copilot`. Common collection ladder, bounds, and identity rules live in
[`provider-collection.md`](../provider-collection.md).

1. Resolve a GitHub token in order:
   1. `COPILOT_GITHUB_TOKEN`, then `GH_TOKEN`, then `GITHUB_TOKEN`, when the value has a Copilot-
      accepted prefix (`gho_`, `ghu_`, `github_pat_`).
   2. Else `$XDG_CONFIG_HOME/github-copilot/apps.json` or `~/.config/github-copilot/apps.json`.
   3. Else `hosts.json` beside it.
   Prefer a `github.com` entry's `oauth_token`. Modern VS Code stores the GitHub login in encrypted
   secret storage rather than these files; Copilot CLI stores OAuth in the macOS Keychain service
   `copilot-cli` or, when that is unavailable, `~/.copilot/config.json`. Those two stores are not
   read here.
2. `GET https://api.github.com/copilot_internal/user` with `Authorization: Bearer` and
   `Accept: application/vnd.github+json`. A 401/403 token is skipped for the next candidate; if
   every candidate is refused, `auth_required`.
3. Map `quota_snapshots.premium_interactions` as the headline **Premium Requests** window
   (`primary_cadence: monthly`, `value_unit: "count"`). `percent_remaining` is inverted to
   `used_percent`. `entitlement: -1` or `unlimited: true` is remaining-only. `chat` and
   `completions` snapshots, when limited, are additional windows. `quota_reset_date` (a calendar
   day) is the reset. When `quota_snapshots` is absent, `limited_user_quotas` remaining counts are
   the fallback. `copilot_plan` is the plan slug. `login` is the global fingerprint.
4. Absent token → `auth_required` with "Run `copilot login`". No browser-session rung.
