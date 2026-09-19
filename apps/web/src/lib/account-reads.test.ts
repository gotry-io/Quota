import { USAGE_HOUR_GRID_RULE } from "@gotry-io/quota-protocol";
import { expect, it } from "vitest";
import {
  accountUsagePeriodPath,
  accountUsagePeriodView,
  parseAccountResponse,
  parseAccountUsagePeriodResponse,
  usagePeriodResourceKey,
} from "./account-reads.ts";

function accountOk() {
  return {
    protocol_version: 2,
    account: {
      account_id: "account_01",
      display_label: "octocat",
      created_at: "2026-01-04T12:00:00Z",
    },
    identities: [{ provider: "github", label: "octocat", linked_at: "2026-01-04T12:00:00Z" }],
  };
}

it("reads account metadata and identities", () => {
  expect(parseAccountResponse(200, accountOk())).toEqual({
    status: "ok",
    account: accountOk(),
  });
  const extra = parseAccountResponse(200, { ...accountOk(), extra: true });
  expect(extra.status).toBe("ok");
  if (extra.status === "ok") {
    expect(extra.account.account.display_label).toBe("octocat");
    expect(extra.account.identities).toEqual(accountOk().identities);
  }
});

it("ignores a body that is not an account answer", () => {
  expect(parseAccountResponse(200, { protocol_version: 2 }).status).toBe("unavailable");
  expect(parseAccountResponse(500, null).status).toBe("unavailable");
});

it("asks the period read with inclusive local dates and the browser timezone", () => {
  expect(
    accountUsagePeriodPath({
      from: "2026-08-26",
      to: "2026-08-26",
      timezone: "Asia/Singapore",
    }),
  ).toBe("/api/v6/account/usage/period?from=2026-08-26&to=2026-08-26&timezone=Asia%2FSingapore");
  expect(
    usagePeriodResourceKey({
      from: "2026-08-26",
      to: "2026-08-26",
      timezone: "Asia/Singapore",
      breakdown: true,
    }),
  ).toBe("2026-08-26|2026-08-26|Asia/Singapore|1");
});

it("reads a period body and maps coverage.partial onto the tree the page draws", () => {
  const totals = {
    total_tokens: 100,
    input_tokens: 80,
    output_tokens: 20,
    cache_read_input_tokens: 0,
    cache_write_input_tokens: 0,
    reasoning_tokens: 0,
    messages: 2,
  };
  const cost = {
    mode: "auto",
    basis: "calculated",
    status: "complete",
    amount_microusd: "5000",
    catalog_revision: null,
    calculated_rows: 1,
    reported_rows: 0,
    unpriced_rows: 0,
    assumptions: [],
    unpriced: [],
  };
  const body = {
    protocol_version: 6,
    request: { from: "2026-08-26", to: "2026-08-26", timezone: "Asia/Singapore" },
    bounds: {
      start: "2026-08-25T16:00:00Z",
      end: "2026-08-26T16:00:00Z",
      grid: USAGE_HOUR_GRID_RULE,
    },
    totals,
    cost,
    cache_saved: { amount_microusd: "0", status: "complete", unpriced_rows: 0 },
    days: [{ date: "2026-08-26", totals, cost, partial: true }],
    extra: true,
    coverage: {
      partial: true,
      daily_retained_from: null,
      hourly_retained_from: null,
      truncated_by_retention: false,
    },
    revision: {
      usage_revision: 1,
      device_generation: 1,
      account_updated_at: "2026-08-26T02:00:00Z",
      pricing_revision: "pricing_1",
      model_catalog_revision: "models_1",
      fold_version: 1,
    },
  };
  const parsed = parseAccountUsagePeriodResponse(200, body);
  expect(parsed.status).toBe("ok");
  if (parsed.status !== "ok") return;
  const view = accountUsagePeriodView(parsed.period);
  expect(view.partial).toBe(true);
  expect(view.agents).toEqual([]);
  expect(view.totals.messages).toBe(2);
});
