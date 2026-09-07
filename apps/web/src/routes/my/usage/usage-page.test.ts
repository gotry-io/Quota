import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { AccountSummaryRead } from "@gotry-io/quota-protocol";
import { cleanup, render, waitFor } from "@testing-library/svelte";
import { afterEach, expect, it, vi } from "vitest";
import { accountActivityRange, clearStoredSummary } from "$lib/account-reads.ts";
import { activityRangeKey, createAccountStore } from "$lib/account-store.svelte.ts";
import { formatUtcDateRange } from "$lib/format.ts";
import UsagePageHarness from "./usage-page-harness.svelte";

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
  vi.useRealTimers();
  clearStoredSummary();
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

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function mockFetch(handler: (url: string) => Response | Promise<Response>): { calls: string[] } {
  const calls: string[] = [];
  vi.stubGlobal("fetch", (async (input: RequestInfo | URL) => {
    const url = String(input);
    calls.push(url);
    return handler(url);
  }) as typeof fetch);
  return { calls };
}

function activityListCalls(calls: string[]): string[] {
  return calls.filter((url) => url.includes("usage/activity") && !url.includes("detail="));
}

it("shows the cache hit rate, what it saved, and reasoning beside the totals", async () => {
  vi.useFakeTimers();
  vi.setSystemTime(new Date("2026-08-12T12:00:00Z"));
  const payload = acceptedSummary();
  const period = payload.usage.last_30_days as Record<string, unknown>;
  period.totals = {
    total_tokens: 1_200,
    input_tokens: 1_000,
    output_tokens: 200,
    cache_read_input_tokens: 940,
    cache_write_input_tokens: 0,
    reasoning_tokens: 150,
    messages: 4,
  };
  period.cache_saved = { amount_microusd: "1500000", status: "complete", unpriced_rows: 0 };
  period.cost = { ...cost(), amount_microusd: "5000", calculated_rows: 4, unpriced_rows: 0 };
  mockFetch((url) => {
    if (url.includes("/account/summary")) return jsonResponse(payload);
    const to = new URL(url, "https://quota.test").searchParams.get("to") ?? "2026-08-12";
    return jsonResponse(activityBody(to));
  });

  const store = createAccountStore();
  await store.ensureSummary();
  const view = render(UsagePageHarness, { store });

  await waitFor(() => {
    expect(view.container.querySelector("#cache-hit")?.textContent?.trim()).toBe("94%");
  });
  expect(view.container.querySelector("#cache-saved")?.textContent?.trim()).toBe("saved $1.50");
  expect(view.container.querySelector("#reasoning-total")?.textContent?.trim()).toBe("150");
  expect(view.container.querySelector("#cost-priced")?.textContent?.trim()).toBe(
    "Priced 4 of 4 rows",
  );
});

it("rolls the Usage activity range once when the shell clock crosses UTC midnight", async () => {
  vi.useFakeTimers();
  vi.setSystemTime(new Date("2026-08-12T23:59:00Z"));
  const payload = acceptedSummary();
  const { calls } = mockFetch((url) => {
    if (url.includes("/account/summary")) return jsonResponse(payload);
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

it("draws Rhythm from the hours detail of the selected period", async () => {
  vi.useFakeTimers();
  vi.setSystemTime(new Date("2026-08-12T12:00:00Z"));
  const hoursOfDay = Array.from({ length: 24 }, (_, hour) => ({
    hour,
    total_tokens: hour === 14 ? 100 : 0,
    cost_microusd: hour === 14 ? "5000" : null,
  }));
  const weekdayHours = Array.from({ length: 7 }, (_, weekday) =>
    Array.from({ length: 24 }, (_, hour) => (weekday === 1 && hour === 14 ? 100 : 0)),
  );
  mockFetch((url) => {
    if (url.includes("/account/summary")) return jsonResponse(acceptedSummary());
    if (url.includes("detail=hours")) {
      return jsonResponse({
        protocol_version: 6,
        days: [
          {
            date: "2026-08-12",
            totals: totals(),
            cost: cost(),
            partial: false,
          },
        ],
        hours_of_day: hoursOfDay,
        weekday_hours: weekdayHours,
      });
    }
    const to = new URL(url, "https://quota.test").searchParams.get("to") ?? "2026-08-12";
    return jsonResponse(activityBody(to));
  });

  const store = createAccountStore();
  await store.ensureSummary();
  const view = render(UsagePageHarness, { store });
  await waitFor(() => {
    expect(view.container.querySelector("#usage-rhythm-title")?.textContent?.trim()).toBe("Rhythm");
  });
  expect(view.container.querySelector(".usage-rhythm-heat")).not.toBeNull();
  expect(view.container.querySelectorAll(".usage-rhythm-cell")).toHaveLength(7 * 24);
});
