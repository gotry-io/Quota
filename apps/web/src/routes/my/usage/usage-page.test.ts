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
