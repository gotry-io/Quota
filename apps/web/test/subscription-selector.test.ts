import assert from "node:assert/strict";
import test from "node:test";
import {
  hashSelectorPreimage,
  subscriptionSelector,
  subscriptionSelectorPreimage,
} from "../src/lib/subscription-selector.ts";

// The same selectors are pinned in the Rust service and the Swift clients: a changed preimage
// orphans every threshold stored under the old key.
test("hashes global and source-scoped subscriptions to the selectors Rust and Swift produce", async () => {
  const global = {
    provider: "codex",
    fingerprint: "account_test",
    fingerprint_scope: "global",
  } as const;
  assert.equal(await subscriptionSelector(global), "ccfc96629357");
  assert.equal(await subscriptionSelector({ ...global, source_id: "" }), "ccfc96629357");
  // The account store hashes the summary's own `key`, which must be this preimage.
  assert.equal(await hashSelectorPreimage("codex|account_test|global|"), "ccfc96629357");

  const scoped = {
    provider: "grok",
    fingerprint: "fp-source",
    fingerprint_scope: "source",
    source_id: "local",
  } as const;
  assert.equal(subscriptionSelectorPreimage(scoped), "grok|fp-source|source|local");
  assert.equal(await subscriptionSelector(scoped), "bf475adb085d");
});
