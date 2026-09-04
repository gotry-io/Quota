import assert from "node:assert/strict";
import test from "node:test";
import {
  hashSelectorPreimage,
  subscriptionSelector,
  subscriptionSelectorPreimage,
} from "../src/lib/subscription-selector.ts";

test("hashes a known global subscription to twelve lowercase hex characters", async () => {
  assert.equal(
    await subscriptionSelector({
      provider: "codex",
      fingerprint: "account_test",
      fingerprint_scope: "global",
    }),
    "ccfc96629357",
  );
});

test("treats a missing source id the same as an empty one", async () => {
  const omitted = await subscriptionSelector({
    provider: "codex",
    fingerprint: "account_test",
    fingerprint_scope: "global",
  });
  const empty = await subscriptionSelector({
    provider: "codex",
    fingerprint: "account_test",
    fingerprint_scope: "global",
    source_id: "",
  });
  assert.equal(omitted, empty);
});

test("includes a source-scoped identity in the preimage", async () => {
  assert.equal(
    subscriptionSelectorPreimage({
      provider: "grok",
      fingerprint: "fp-source",
      fingerprint_scope: "source",
      source_id: "local",
    }),
    "grok|fp-source|source|local",
  );
  assert.equal(
    await subscriptionSelector({
      provider: "grok",
      fingerprint: "fp-source",
      fingerprint_scope: "source",
      source_id: "local",
    }),
    "bf475adb085d",
  );
});

test("hashes a summary key as the same preimage", async () => {
  assert.equal(await hashSelectorPreimage("codex|account_test|global|"), "ccfc96629357");
});
