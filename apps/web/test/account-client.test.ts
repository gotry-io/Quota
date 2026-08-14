import assert from "node:assert/strict";
import test from "node:test";
import { accountUsageDayPath, parseAccountUsageDayResponse } from "../src/lib/account-usage-day.ts";

function emptyTotals() {
  return {
    input_tokens: 10,
    cache_read_tokens: 0,
    cache_write_5m_tokens: 0,
    cache_write_1h_tokens: 0,
    cache_write_inferred_tokens: 0,
    output_tokens: 4,
    reasoning_tokens: 0,
    requests: 1,
    web_search_requests: 0,
    web_fetch_requests: 0,
    source_cost_microusd: null,
    source_cost_covered_requests: 0,
  };
}

function emptyCost() {
  return {
    mode: "calculate",
    basis: "calculated",
    status: "complete",
    amount_microusd: "1000000",
    catalog_revision: null,
    calculated_rows: 1,
    reported_rows: 0,
    unpriced_rows: 0,
    assumptions: [],
    unpriced: [],
  };
}

function usageResponse(date: string) {
  return {
    protocol_version: 3,
    usage: {
      range: { from: date, to: date },
      totals: emptyTotals(),
      cost: emptyCost(),
      coverage: [],
      breakdowns: [
        {
          dimension: "usage_date",
          key: date,
          totals: emptyTotals(),
          cost: emptyCost(),
        },
      ],
    },
  };
}

test("builds the managed-data v3 single-day usage summary URL", () => {
  const path = accountUsageDayPath("2026-08-14");
  const url = new URL(path, "https://quota.gotry.io");
  assert.equal(url.pathname, "/api/v3/account/usage/summary");
  assert.equal(url.searchParams.get("usage_agents"), "all");
  assert.equal(url.searchParams.get("cost_mode"), "calculate");
  assert.equal(url.searchParams.get("model_catalog"), "1");
  assert.equal(url.searchParams.get("from"), "2026-08-14");
  assert.equal(url.searchParams.get("to"), "2026-08-14");
  assert.equal(
    [...url.searchParams.keys()].sort().join(","),
    "cost_mode,from,model_catalog,to,usage_agents",
  );
});

test("parses single-day usage responses into explicit client statuses", () => {
  const date = "2026-08-14";
  const ok = parseAccountUsageDayResponse(200, usageResponse(date));
  assert.equal(ok.status, "ok");
  if (ok.status === "ok") {
    assert.equal(ok.usage.range.from, date);
    assert.equal(ok.usage.range.to, date);
    assert.equal(ok.usage.totals.input_tokens, 10);
    assert.equal(ok.usage.cost.amount_microusd, "1000000");
  }

  assert.equal(parseAccountUsageDayResponse(401, {}).status, "unauthorized");
  assert.equal(parseAccountUsageDayResponse(500, usageResponse(date)).status, "error");
  assert.equal(parseAccountUsageDayResponse(200, { protocol_version: 2 }).status, "error");
  assert.equal(parseAccountUsageDayResponse(200, null).status, "error");
});
