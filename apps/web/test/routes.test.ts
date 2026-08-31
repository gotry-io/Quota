import assert from "node:assert/strict";
import test from "node:test";
import { DASHBOARD_PATH, planDisplayName, SIGN_IN_PATH, signInHref } from "../src/lib/routes.ts";
import { formatQuotaRemaining } from "../src/lib/format.ts";

test("sends a signed-out visitor to Relay, and back to the page they wanted", () => {
  assert.equal(SIGN_IN_PATH, "/api/auth/github/start");
  assert.equal(signInHref(), SIGN_IN_PATH);
  assert.equal(signInHref(DASHBOARD_PATH), SIGN_IN_PATH);
  assert.equal(
    signInHref("/my?device=device_1"),
    "/api/auth/github/start?return_to=%2Fmy%3Fdevice%3Ddevice_1",
  );
});

test("matches QuotaBar plan capitalization", () => {
  assert.equal(planDisplayName("prolite"), "Pro Lite");
  assert.equal(planDisplayName("max_5x"), "Max 5x");
  assert.equal(planDisplayName("max_20x"), "Max 20x");
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
