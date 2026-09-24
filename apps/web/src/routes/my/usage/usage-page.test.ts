import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { AccountSummaryRead, UsagePeriodRead } from "@gotry-io/quota-protocol";
import {
  AccountUsagePeriodResponseReadSchema,
  USAGE_HOUR_GRID_RULE,
} from "@gotry-io/quota-protocol";
import { cleanup, render, waitFor } from "@testing-library/svelte";
import { afterEach, expect, it, vi } from "vitest";
import {
  accountActivityRange,
  clearStoredPeriods,
  clearStoredSummary,
} from "$lib/account-reads.ts";
import { clearStoredAccountSettings } from "$lib/account-settings-client.ts";
import { activityRangeKey, createAccountStore } from "$lib/account-store.svelte.ts";
import { formatUtcDateRange } from "$lib/format.ts";
import UsagePageHarness from "./usage-page-harness.svelte";

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
  vi.useRealTimers();
  clearStoredSummary();
  clearStoredPeriods();
  clearStoredAccountSettings();
});

type WireCase = { accepted: boolean; payload: unknown };

function acceptedSummary(): AccountSummaryRead {
  const fixture = JSON.parse(
    readFileSync(
      join(
        dirname(fileURLToPath(import.meta.url)),
        "../../../../../../packages/protocol/fixtures/wire-conformance.json",
      ),
      "utf8",
    ),
  ) as { contracts: { account_summary: WireCase[] } };
  const accepted = fixture.contracts.account_summary.find((item) => item.accepted);
  if (!accepted) throw new Error("wire-conformance.json has no accepted account_summary");
  return structuredClone(accepted.payload) as AccountSummaryRead;
}

function totals() {
  return {
    total_tokens: 100,
    input_tokens: 80,
    output_tokens: 20,
    cache_read_input_tokens: 0,
    cache_write_input_tokens: 0,
    reasoning_tokens: 0,
    messages: 1,
  };
}

function cost() {
  return {
    mode: "auto" as const,
    basis: "calculated" as const,
    status: "complete" as const,
    amount_microusd: "5000",
    catalog_revision: null,
    calculated_rows: 1,
    reported_rows: 0,
    unpriced_rows: 0,
    assumptions: [] as string[],
    unpriced: [] as UsagePeriodRead["cost"]["unpriced"],
  };
}

function activityBody(date: string) {
  return {
    protocol_version: 6,
    days: [
      {
        date,
        totals: totals(),
        cost: cost(),
        partial: false,
      },
    ],
  };
}

function nextDate(date: string): string {
  const shifted = new Date(`${date}T00:00:00Z`);
  shifted.setUTCDate(shifted.getUTCDate() + 1);
  return shifted.toISOString().slice(0, 10);
}

function periodBody(input: {
  from: string;
  to: string;
  timezone: string;
  usage: UsagePeriodRead;
  breakdown?: boolean;
  truncated?: boolean;
  days?: Array<{
    date: string;
    totals: UsagePeriodRead["totals"];
    cost: UsagePeriodRead["cost"];
    partial: boolean;
  }>;
}) {
  return {
    protocol_version: 6,
    request: { from: input.from, to: input.to, timezone: input.timezone },
    bounds: {
      start: `${input.from}T00:00:00Z`,
      end: `${nextDate(input.to)}T00:00:00Z`,
      grid: USAGE_HOUR_GRID_RULE,
    },
    totals: input.usage.totals,
    cost: input.usage.cost,
    cache_saved: input.usage.cache_saved,
    days: input.days ?? [
      {
        date: input.from,
        totals: input.usage.totals,
        cost: input.usage.cost,
        partial: input.usage.partial,
      },
    ],
    ...(input.breakdown === false ? {} : { agents: input.usage.agents }),
    coverage: {
      partial: input.usage.partial,
      daily_retained_from: null,
      hourly_retained_from: null,
      truncated_by_retention: input.truncated === true,
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

function periodFromSummary(url: string, summary: AccountSummaryRead) {
  const asked = new URL(url, "https://quota.test");
  const from = asked.searchParams.get("from") ?? "2026-08-12";
  const to = asked.searchParams.get("to") ?? from;
  const timezone = asked.searchParams.get("timezone") ?? "UTC";
  const breakdown = asked.searchParams.get("breakdown") === "1";
  const span =
    Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000) + 1;
  const usage =
    span === 1
      ? summary.usage.today
      : span === 7
        ? summary.usage.last_7_days
        : summary.usage.last_30_days;
  return periodBody({ from, to, timezone, usage, breakdown });
}

function jsonResponse(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...headers },
  });
}

function settingsBody(
  budget: { amount_usd: string | null; alerts: boolean } = { amount_usd: null, alerts: true },
  revision = budget.amount_usd === null ? 0 : 1,
) {
  return {
    protocol_version: 2,
    revision,
    updated_at: revision === 0 ? "1970-01-01T00:00:00Z" : "2026-09-21T10:00:00.000Z",
    alerts: { reset_reminders: true, pace_alerts: true, thresholds: {} },
    budget,
  };
}

function mockFetch(
  handler: (url: string, init?: RequestInit) => Response | Promise<Response>,
  settings: ReturnType<typeof settingsBody> = settingsBody(),
): { calls: string[] } {
  const calls: string[] = [];
  vi.stubGlobal("fetch", (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    calls.push(url);
    if (url.includes("/account/settings")) {
      if ((init?.method ?? "GET") === "PUT") {
        const posted = JSON.parse(String(init?.body ?? "{}")) as {
          alerts: (typeof settings)["alerts"];
          budget: (typeof settings)["budget"];
        };
        const next = {
          ...settings,
          revision: settings.revision + 1,
          updated_at: "2026-09-21T10:00:00.000Z",
          alerts: posted.alerts,
          budget: posted.budget,
        };
        return jsonResponse(next, 200, { ETag: `"${next.revision}"` });
      }
      return jsonResponse(settings, 200, { ETag: `"${settings.revision}"` });
    }
    return handler(url, init);
  }) as typeof fetch);
  return { calls };
}

function activityListCalls(calls: string[]): string[] {
  return calls.filter((url) => url.includes("usage/activity") && !url.includes("detail="));
}

it("rolls the Usage activity range once when the shell clock crosses UTC midnight", async () => {
  vi.useFakeTimers();
  vi.setSystemTime(new Date("2026-08-12T23:59:00Z"));
  const payload = acceptedSummary();
  const { calls } = mockFetch((url) => {
    if (url.includes("/account/summary")) return jsonResponse(payload);
    if (url.includes("/account/usage/period")) return jsonResponse(periodFromSummary(url, payload));
    const to = new URL(url, "https://quota.test").searchParams.get("to") ?? "2026-08-12";
    return jsonResponse(activityBody(to));
  });

  const store = createAccountStore();
  await store.ensureSummary();
  const stopClock = store.startClock();
  const firstRange = accountActivityRange(new Date("2026-08-12T23:59:00Z"));
  const firstKey = activityRangeKey(firstRange);
  expect(firstKey).toBe("2025-08-13|2026-08-12");

  const view = render(UsagePageHarness, { store });
  await waitFor(() => {
    expect(view.container.querySelector("#usage-activity-status")?.textContent?.trim()).toBe(
      formatUtcDateRange(firstRange.from, firstRange.to),
    );
  });
  expect(Object.keys(store.activity)).toEqual([firstKey]);
  expect(activityListCalls(calls)).toHaveLength(1);
  expect(activityListCalls(calls)[0]).toContain("from=2025-08-13");
  expect(activityListCalls(calls)[0]).toContain("to=2026-08-12");

  await vi.advanceTimersByTimeAsync(120_000);
  const secondRange = accountActivityRange(new Date("2026-08-13T00:01:00Z"));
  const secondKey = activityRangeKey(secondRange);
  expect(secondKey).toBe("2025-08-14|2026-08-13");

  await waitFor(() => {
    expect(view.container.querySelector("#usage-activity-status")?.textContent?.trim()).toBe(
      formatUtcDateRange(secondRange.from, secondRange.to),
    );
  });
  expect(store.activity[secondKey]?.data).not.toBeNull();
  expect(activityListCalls(calls)).toHaveLength(2);
  expect(activityListCalls(calls)[1]).toContain("from=2025-08-14");
  expect(activityListCalls(calls)[1]).toContain("to=2026-08-13");

  await vi.advanceTimersByTimeAsync(60_000);
  await waitFor(() => {
    expect(view.container.querySelector("#usage-activity-status")?.textContent?.trim()).toBe(
      formatUtcDateRange(secondRange.from, secondRange.to),
    );
  });
  expect(activityListCalls(calls)).toHaveLength(2);
  stopClock();
});

it("parses a period response and renders totals, cost, and coverage", async () => {
  vi.useFakeTimers();
  vi.setSystemTime(new Date("2026-08-12T12:00:00Z"));
  const payload = acceptedSummary();
  const usage = {
    ...payload.usage.last_30_days,
    totals: {
      ...payload.usage.last_30_days.totals,
      total_tokens: 2_400,
      input_tokens: 2_000,
      output_tokens: 400,
      messages: 6,
    },
    cost: { ...cost(), amount_microusd: "1230000" },
    partial: true,
  };
  mockFetch((url) => {
    if (url.includes("/account/summary")) return jsonResponse(payload);
    if (url.includes("/account/usage/period")) {
      const asked = new URL(url, "https://quota.test");
      const from = asked.searchParams.get("from") ?? "2026-07-14";
      const to = asked.searchParams.get("to") ?? "2026-08-12";
      const timezone = asked.searchParams.get("timezone") ?? "UTC";
      const breakdown = asked.searchParams.get("breakdown") === "1";
      const body = periodBody({
        from,
        to,
        timezone,
        usage,
        breakdown,
        truncated: true,
        days: [
          {
            date: from,
            totals: usage.totals,
            cost: usage.cost,
            partial: true,
          },
        ],
      });
      expect(AccountUsagePeriodResponseReadSchema.safeParse(body).success).toBe(true);
      return jsonResponse(body);
    }
    const to = new URL(url, "https://quota.test").searchParams.get("to") ?? "2026-08-12";
    return jsonResponse(activityBody(to));
  });

  const store = createAccountStore();
  await store.ensureSummary();
  const view = render(UsagePageHarness, { store });
  await waitFor(() => {
    expect(view.container.querySelector("#token-total")?.textContent?.trim()).toBe("2.4K");
  });
  expect(view.container.querySelector("#cost-total")?.textContent).toContain("$1.23");
  expect(view.container.querySelector("#usage-retention-note")?.textContent).toContain(
    "This range goes past what Quota still keeps.",
  );
  expect(view.container.querySelector(".dashboard-status")?.textContent).toContain(
    "some hours incomplete",
  );
  expect(view.container.querySelector(".dashboard-status")?.textContent).toContain(
    "some of this range is no longer kept",
  );
  expect(view.container.textContent).toContain(
    "Some hours in this period were scanned incompletely.",
  );
});

it("meters the monthly budget from the Account document", async () => {
  vi.useFakeTimers();
  vi.setSystemTime(new Date("2026-08-12T12:00:00Z"));
  const payload = acceptedSummary();
  mockFetch(
    (url) => {
      if (url.includes("/account/summary")) return jsonResponse(payload);
      if (url.includes("/account/usage/period"))
        return jsonResponse(periodFromSummary(url, payload));
      const to = new URL(url, "https://quota.test").searchParams.get("to") ?? "2026-08-12";
      return jsonResponse(activityBody(to));
    },
    settingsBody({ amount_usd: "50.00", alerts: true }, 1),
  );

  const store = createAccountStore();
  await store.ensureSummary();
  const view = render(UsagePageHarness, { store });
  await waitFor(() => {
    expect(view.container.querySelector("#usage-budget-value")?.textContent).toContain("$50.00");
  });
  expect(view.container.textContent).toContain("This budget follows your Account.");
  expect(view.container.querySelector("#usage-budget-value")?.textContent).toMatch(
    /\/ \$50\.00 · /,
  );
});
