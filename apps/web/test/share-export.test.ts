import assert from "node:assert/strict";
import test from "node:test";
import { AccountSummarySchema } from "@gotry-io/quota-protocol";
import { buildShareExport, shareInputFromAccountSummary } from "../src/share-export.ts";

const emptyCost = {
  mode: "calculate",
  basis: "calculated",
  status: "complete",
  amount_microusd: "50240000",
  catalog_revision: "pricing_1",
  calculated_rows: 1,
  reported_rows: 0,
  unpriced_rows: 0,
  assumptions: [],
  unpriced: [],
} as const;

const emptyTotals = {
  input_tokens: 1000,
  cache_read_tokens: 0,
  cache_write_5m_tokens: 0,
  cache_write_1h_tokens: 0,
  cache_write_inferred_tokens: 0,
  output_tokens: 200,
  reasoning_tokens: 0,
  requests: 1,
  web_search_requests: 0,
  web_fetch_requests: 0,
  source_cost_microusd: null,
  source_cost_covered_requests: 0,
};

test("share export includes remaining quota and usage consumption", () => {
  const exported = buildShareExport({
    display_label: "octocat",
    quota: [
      {
        provider: "codex",
        plan: "Plus",
        windows: [{ title: "Weekly", used_percent: 25 }],
      },
      {
        provider: "openrouter",
        plan: "Credits",
        windows: [
          { title: "Balance (USD)", used_percent: 0, remaining_value: 12.5, value_unit: "usd" },
        ],
      },
    ],
    usage: {
      range: { from: "2026-08-01", to: "2026-08-13" },
      tokens: 1_200,
      cost_label: "$50.24",
      models: [{ name: "gpt-5", tokens: 900, cost_label: "$40.00" }],
    },
  });
  assert.match(exported.quota_text, /remaining quota/);
  assert.match(exported.quota_text, /Weekly: 75%/);
  assert.match(exported.quota_text, /Balance \(USD\): \$12\.50/);
  assert.match(exported.usage_text, /usage 2026-08-01–2026-08-13/);
  assert.match(exported.usage_text, /Tokens 1.2K · \$50\.24/);
  assert.match(exported.usage_text, /gpt-5/);
  assert.match(exported.quota_svg, /Remaining quota/);
  assert.match(exported.usage_svg, /API-equivalent cost/);
  assert.doesNotMatch(exported.quota_text, /device_/);
  assert.doesNotMatch(exported.usage_svg, /device_/);
});

test("share input from account summary keeps remaining quota and drops later device duplicates", () => {
  const summary = AccountSummarySchema.parse({
    protocol_version: 2,
    generated_at: "2026-08-13T12:00:00Z",
    account: {
      account_id: "account_01",
      display_label: "octocat",
      created_at: "2026-07-01T00:00:00Z",
    },
    devices: [
      {
        device_id: "device_01",
        display_name: "Studio Mac",
        platform: "macos",
        device_generation: 1,
        status: "active",
        created_at: "2026-07-01T00:00:00Z",
        last_login_at: "2026-08-01T00:00:00Z",
        last_seen_at: "2026-08-13T12:00:00Z",
        signed_out_at: null,
      },
    ],
    quota: [
      {
        device_id: "device_01",
        sequence: 2,
        captured_at: "2026-08-13T12:00:00Z",
        updated_at: "2026-08-13T12:00:00Z",
        snapshot: {
          provider: "codex",
          account: {
            fingerprint: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            fingerprint_scope: "global",
            label: "octocat",
            plan: "Plus",
          },
          windows: [{ id: "weekly", title: "Weekly", used_percent: 40 }],
          source: "codex_rpc",
          status: "available",
          observed_at: "2026-08-13T12:00:00Z",
        },
      },
    ],
    usage: {
      range: { from: "2026-08-01", to: "2026-08-13" },
      totals: emptyTotals,
      cost: emptyCost,
      coverage: [],
      breakdowns: [
        {
          dimension: "model",
          key: "gpt-5",
          totals: emptyTotals,
          cost: emptyCost,
        },
      ],
    },
  });
  const input = shareInputFromAccountSummary(summary);
  assert.equal(input.display_label, "octocat");
  assert.equal(input.quota[0]?.provider, "codex");
  assert.equal(input.quota[0]?.windows[0]?.title, "Weekly");
  assert.equal(input.usage.tokens, 1200);
  assert.equal(input.usage.models[0]?.name, "gpt-5");
  const exported = buildShareExport(input);
  assert.match(exported.quota_text, /Weekly: 60%/);
  assert.doesNotMatch(exported.quota_text, /device_01/);
  assert.doesNotMatch(exported.usage_text, /aaaaaaaa/);
});
