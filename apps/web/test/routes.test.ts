import assert from "node:assert/strict";
import test from "node:test";
import { accountEntryAction, DASHBOARD_PATH, legacyDashboardRedirect } from "../src/routes.ts";

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
