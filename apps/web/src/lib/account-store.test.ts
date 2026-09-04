import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { AccountSummaryRead } from "@gotry-io/quota-protocol";
import { afterEach, expect, it, vi } from "vitest";
import { clearStoredSummary } from "./account-reads.ts";
import { activityRangeKey, createAccountStore } from "./account-store.svelte.ts";

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
  clearStoredSummary();
});

type WireCase = { accepted: boolean; payload: unknown };

function acceptedSummary(): AccountSummaryRead {
  const fixture = JSON.parse(
    readFileSync(
      join(
        dirname(fileURLToPath(import.meta.url)),
        "../../../../packages/protocol/fixtures/wire-conformance.json",
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

function activityBody(date = "2026-08-12", detailed = false) {
  const day = {
    date,
    totals: totals(),
    cost: cost(),
    partial: false,
    ...(detailed
      ? {
          agents: [
            {
              agent: "codex",
              providers: [
                {
                  provider: "openai",
                  models: [{ model: "gpt-5", totals: totals(), cost: cost() }],
                },
              ],
            },
          ],
        }
      : {}),
  };
  return { protocol_version: 6, days: [day] };
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((next) => {
    resolve = next;
  });
  return { promise, resolve };
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

it("reuses a fresh summary and joins an in-flight read", async () => {
  const payload = acceptedSummary();
  const gate = deferred<Response>();
  const { calls } = mockFetch(() => gate.promise);

  const store = createAccountStore();
  const first = store.ensureSummary();
  const second = store.ensureSummary();
  expect(calls).toHaveLength(1);

  gate.resolve(jsonResponse(payload));
  await Promise.all([first, second]);
  expect(store.summaryStatus).toBe("ready");
  expect(store.summary?.account.display_label).toBe(payload.account.display_label);

  await store.ensureSummary();
  expect(calls).toHaveLength(1);
});

it("hashes subscription selectors in parallel and caches them", async () => {
  const payload = acceptedSummary();
  const seed = payload.subscriptions[0];
  if (!seed) throw new Error("accepted summary has no subscription");
  payload.subscriptions = [seed, { ...structuredClone(seed), key: `${seed.key}|other` }];

  const realDigest = crypto.subtle.digest.bind(crypto.subtle);
  let inflight = 0;
  let maxInflight = 0;
  let digestCalls = 0;
  vi.spyOn(crypto.subtle, "digest").mockImplementation(async (algorithm, data) => {
    digestCalls += 1;
    inflight += 1;
    maxInflight = Math.max(maxInflight, inflight);
    await new Promise((resolve) => setTimeout(resolve, 20));
    inflight -= 1;
    return realDigest(algorithm, data);
  });

  mockFetch(() => jsonResponse(payload));
  const store = createAccountStore();
  await store.ensureSummary();
  expect(maxInflight).toBeGreaterThan(1);
  expect(Object.keys(store.subscriptionSelectors)).toHaveLength(2);
  const firstDigests = digestCalls;

  await store.refresh();
  expect(digestCalls).toBe(firstDigests);
});

it("keeps stale summary visible while a revalidation runs", async () => {
  const payload = acceptedSummary();
  mockFetch(() => jsonResponse(payload));
  const store = createAccountStore();
  await store.ensureSummary();
  const fetchedAt = store.summaryFetchedAt;
  expect(fetchedAt).not.toBeNull();

  const gate = deferred<Response>();
  const { calls } = mockFetch(() => gate.promise);
  const returned = store.ensureSummary({ maxAgeMs: 0 });
  await returned;
  expect(store.summary).not.toBeNull();
  expect(calls).toHaveLength(1);

  gate.resolve(jsonResponse(payload));
  await vi.waitFor(() => expect(store.summaryFetchedAt).not.toBe(fetchedAt));
});

it("keeps the last summary on 401 and other errors", async () => {
  const payload = acceptedSummary();
  mockFetch(() => jsonResponse(payload));
  const store = createAccountStore();
  await store.ensureSummary();

  mockFetch(() => new Response(null, { status: 401 }));
  await store.refresh();
  expect(store.summary?.account.display_label).toBe(payload.account.display_label);
  expect(store.summaryStatus).toBe("error");
  expect(store.loadError?.status).toBe("session_ended");
  expect(store.loadError?.action?.type).toBe("sign_in");

  mockFetch(() => new Response(null, { status: 500 }));
  await store.refresh();
  expect(store.summary).not.toBeNull();
  expect(store.loadError?.status).toBe("unavailable");
});

it("stores activity by range and day detail by date", async () => {
  const payload = acceptedSummary();
  mockFetch((url) => {
    if (url.includes("/account/summary")) return jsonResponse(payload);
    if (url.includes("detail=agents")) return jsonResponse(activityBody("2026-08-12", true));
    return jsonResponse(activityBody());
  });

  const store = createAccountStore();
  const range = store.activityRange;
  await store.ensureActivity(range);
  await store.ensureActivity(range);
  const key = activityRangeKey(range);
  expect(store.activity[key]?.status).toBe("ready");
  expect(store.activity[key]?.data).toHaveLength(1);

  await store.ensureDay("2026-08-12");
  await store.ensureDay("2026-08-12");
  expect(store.dayDetail["2026-08-12"]?.data?.agents).toHaveLength(1);
});
