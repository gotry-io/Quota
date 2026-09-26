import { USAGE_HOUR_GRID_RULE } from "@gotry-io/quota-protocol";
import { cleanup, render, waitFor } from "@testing-library/svelte";
import { afterEach, expect, it, vi } from "vitest";
import { clearStoredPeriods } from "$lib/account-reads.ts";
import { clearStoredAccountSettings } from "$lib/account-settings-client.ts";
import { createAccountStore } from "$lib/account-store.svelte.ts";
import MonthlyBudget from "./MonthlyBudget.svelte";

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
  vi.useRealTimers();
  clearStoredPeriods();
  clearStoredAccountSettings();
});

const totals = {
  total_tokens: 100,
  input_tokens: 80,
  output_tokens: 20,
  cache_read_input_tokens: 0,
  cache_write_input_tokens: 0,
  reasoning_tokens: 0,
  messages: 1,
};

const cost = {
  mode: "auto",
  basis: "calculated",
  status: "complete",
  amount_microusd: "20000000",
  catalog_revision: null,
  calculated_rows: 1,
  reported_rows: 0,
  unpriced_rows: 0,
  assumptions: [],
  unpriced: [],
};

function nextDate(date: string): string {
  const shifted = new Date(`${date}T00:00:00Z`);
  shifted.setUTCDate(shifted.getUTCDate() + 1);
  return shifted.toISOString().slice(0, 10);
}

function periodBody(url: string) {
  const asked = new URL(url, "https://quota.test");
  const from = asked.searchParams.get("from") ?? "2026-08-01";
  const to = asked.searchParams.get("to") ?? "2026-08-31";
  return {
    protocol_version: 6,
    request: { from, to, timezone: asked.searchParams.get("timezone") ?? "UTC" },
    bounds: {
      start: `${from}T00:00:00Z`,
      end: `${nextDate(to)}T00:00:00Z`,
      grid: USAGE_HOUR_GRID_RULE,
    },
    totals,
    cost,
    cache_saved: { amount_microusd: "0", status: "complete", unpriced_rows: 0 },
    days: [{ date: from, totals, cost, partial: false }],
    coverage: {
      partial: false,
      daily_retained_from: null,
      hourly_retained_from: null,
      truncated_by_retention: false,
    },
    revision: {
      usage_revision: 1,
      device_generation: 1,
      account_updated_at: "2026-08-12T12:00:00Z",
      pricing_revision: "pricing_1",
      model_catalog_revision: "models_1",
      fold_version: 1,
    },
  };
}

it("meters this month's spend against the budget the Account document holds", async () => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(new Date("2026-08-12T12:00:00Z"));
  vi.stubGlobal("fetch", async (input: RequestInfo | URL) => {
    const url = String(input);
    const body = url.includes("/account/settings")
      ? {
          protocol_version: 2,
          revision: 1,
          updated_at: "2026-08-01T10:00:00.000Z",
          alerts: { reset_reminders: true, pace_alerts: true, thresholds: {} },
          budget: { amount_usd: "50.00", alerts: true },
          history: { sync: false },
        }
      : periodBody(url);
    return new Response(JSON.stringify(body), {
      status: 200,
      headers: { "Content-Type": "application/json", ETag: '"1"' },
    });
  });

  const view = render(MonthlyBudget, { store: createAccountStore() });
  await waitFor(() => {
    expect(view.container.querySelector("#usage-budget-value")?.textContent).toMatch(
      /^\$20\.00 \/ \$50\.00 · 40%$/,
    );
  });
});
