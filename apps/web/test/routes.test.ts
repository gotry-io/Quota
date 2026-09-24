import assert from "node:assert/strict";
import test from "node:test";
import { formatQuotaRemaining } from "../src/lib/format.ts";
import {
  DASHBOARD_PATH,
  DELETE_ACCOUNT_RETURN_PATH,
  identityLinkHref,
  identityStartHref,
  isDeleteAccountReturn,
  SIGN_IN_METHOD_ORDER,
  SIGN_IN_PATH,
  signInHref,
  signInReturnPath,
} from "../src/lib/routes.ts";

test("starts one provider round trip, and only for a page on this origin", () => {
  assert.equal(signInHref(DASHBOARD_PATH), SIGN_IN_PATH);
  assert.equal(signInHref("/my?device=device_1"), "/sign-in?return_to=%2Fmy%3Fdevice%3Ddevice_1");
  assert.deepEqual(SIGN_IN_METHOD_ORDER, ["apple", "github", "email"]);
  assert.equal(identityStartHref("github", "/my"), "/api/auth/github/start?return_to=%2Fmy");
  assert.equal(
    identityLinkHref("apple"),
    "/api/auth/apple/start?intent=link&return_to=%2Fmy%2Fsettings",
  );
  assert.equal(DELETE_ACCOUNT_RETURN_PATH, "/my/settings?delete=account");
  assert.equal(isDeleteAccountReturn("/my/settings?delete=account"), true);
  assert.equal(isDeleteAccountReturn("/my/settings"), false);
  assert.equal(signInReturnPath("/my?device=device_1"), "/my?device=device_1");
  for (const refused of [
    "https://attacker.invalid/",
    "//attacker.invalid/",
    "/my\\@attacker.invalid",
    "/my with space",
    "my",
    `/${"m".repeat(512)}`,
  ]) {
    assert.equal(signInReturnPath(refused), null, refused);
  }
});

test("keeps Cursor included-usage money out of compact quota cards", () => {
  const window = {
    id: "other_models",
    used_percent: 63.102,
    remaining_value: 14.55,
    limit_value: 400,
    value_unit: "usd",
  };
  assert.equal(formatQuotaRemaining(window, "cursor"), "36.9%");
  assert.equal(formatQuotaRemaining(window, "openrouter"), "36.9% · $14.55");
});
