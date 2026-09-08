import assert from "node:assert/strict";
import test from "node:test";
import { parseAccountResponse } from "../src/lib/account-reads.ts";
import { accountReadFromSummary, screenshotAccountSummary } from "../e2e/account-fixture.ts";

test("screenshot account fixture matches the Account read", () => {
  const visual = parseAccountResponse(200, accountReadFromSummary(screenshotAccountSummary()));
  assert.equal(visual.status, "ok", visual.status === "ok" ? "" : visual.message);
  const smoke = parseAccountResponse(200, accountReadFromSummary());
  assert.equal(smoke.status, "ok", smoke.status === "ok" ? "" : smoke.message);
});
