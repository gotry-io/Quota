import assert from "node:assert/strict";
import test from "node:test";
import { AccountResponseSchema } from "@gotry-io/quota-protocol";
import { accountReadFromSummary, screenshotAccountSummary } from "../e2e/account-fixture.ts";

test("screenshot account fixture matches AccountResponse", () => {
  const visual = AccountResponseSchema.safeParse(
    accountReadFromSummary(screenshotAccountSummary()),
  );
  assert.equal(visual.success, true, visual.success ? "" : visual.error.message);
  const smoke = AccountResponseSchema.safeParse(accountReadFromSummary());
  assert.equal(smoke.success, true, smoke.success ? "" : smoke.error.message);
});
