import assert from "node:assert/strict";
import test from "node:test";
import {
  accountEntryAction,
  DASHBOARD_PATH,
  legacyDashboardRedirect,
  planDisplayName,
  publicProfileUsername,
} from "../src/lib/routes.ts";
import { formatQuotaRemaining } from "../src/lib/format.ts";

test("keeps the shipped /app dashboard bookmark as a single redirect", () => {
  assert.equal(DASHBOARD_PATH, "/my");
  assert.equal(legacyDashboardRedirect("/app"), "/my");
  assert.equal(legacyDashboardRedirect("/app/anything"), "/my");
  assert.equal(legacyDashboardRedirect("/my"), null);
});

test("opens an existing account instead of starting GitHub sign-in again", () => {
  assert.equal(accountEntryAction(200), "dashboard");
  assert.equal(accountEntryAction(204), "dashboard");
  assert.equal(accountEntryAction(401), "login");
  assert.equal(accountEntryAction(500), "error");
});

test("parses public profile usernames and rejects invalid slugs", () => {
  assert.equal(publicProfileUsername("/u/octocat"), "octocat");
  assert.equal(publicProfileUsername("/u/ada-lovelace"), "ada-lovelace");
  assert.equal(publicProfileUsername("/u/Octocat"), "octocat");
  assert.equal(publicProfileUsername("/my"), null);
});

test("matches QuotaBar plan capitalization", () => {
  assert.equal(planDisplayName("prolite"), "Pro Lite");
  assert.equal(planDisplayName("supergrok"), "SuperGrok");
  assert.equal(planDisplayName("Credits"), "Credits");
  assert.equal(planDisplayName("custom_plan"), "Custom Plan");
  assert.equal(planDisplayName("Already Named"), "Already Named");
});

test("keeps Cursor included-usage money out of compact quota cards", () => {
  const window = {
    id: "other_models",
    used_percent: 63.102,
    remaining_value: 14.55,
    limit_value: 400,
    value_unit: "usd",
  };
  assert.equal(formatQuotaRemaining(window, "cursor"), "37%");
  assert.equal(formatQuotaRemaining(window, "openrouter"), "37% · $14.55");
});
