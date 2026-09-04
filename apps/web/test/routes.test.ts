import assert from "node:assert/strict";
import test from "node:test";
import { formatQuotaRemaining } from "../src/lib/format.ts";
import { KNOWN_PLANS } from "../src/lib/plan-display.generated.ts";
import {
  accountPageTitle,
  DASHBOARD_PATH,
  DEVICES_PATH,
  isAccountShellPath,
  isSubscriptionPath,
  isUsagePath,
  planDisplayName,
  SETTINGS_PATH,
  SIGN_IN_PATH,
  signInHref,
  subscriptionPath,
  USAGE_PATH,
} from "../src/lib/routes.ts";

test("sends a signed-out visitor to Relay, and back to the page they wanted", () => {
  assert.equal(SIGN_IN_PATH, "/api/auth/github/start");
  assert.equal(signInHref(), SIGN_IN_PATH);
  assert.equal(signInHref(DASHBOARD_PATH), SIGN_IN_PATH);
  assert.equal(
    signInHref("/my?device=device_1"),
    "/api/auth/github/start?return_to=%2Fmy%3Fdevice%3Ddevice_1",
  );
});

test("names the account sub-routes and hashes a selector into the subscription path", () => {
  assert.equal(USAGE_PATH, "/my/usage");
  assert.equal(DEVICES_PATH, "/my/devices");
  assert.equal(SETTINGS_PATH, "/my/settings");
  assert.equal(subscriptionPath("ccfc96629357"), "/my/subscriptions/ccfc96629357");
  assert.equal(isAccountShellPath("/my"), true);
  assert.equal(isAccountShellPath("/my/usage"), true);
  assert.equal(isAccountShellPath("/"), false);
  assert.equal(isSubscriptionPath("/my/subscriptions/ccfc96629357"), true);
  assert.equal(isSubscriptionPath("/my"), false);
  assert.equal(isUsagePath("/my/usage"), true);
  assert.equal(isUsagePath("/my"), false);
  assert.equal(accountPageTitle("/my"), "Overview");
  assert.equal(accountPageTitle("/my/usage"), "Usage");
  assert.equal(accountPageTitle("/my/devices"), "Devices");
  assert.equal(accountPageTitle("/my/settings"), "Settings");
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

test("resolves a generated plan display row", () => {
  assert.equal(KNOWN_PLANS.max5x, "Max 5x");
  assert.equal(planDisplayName("max_5x"), "Max 5x");
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
