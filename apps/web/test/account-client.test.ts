import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { USAGE_HOUR_GRID_RULE } from "@gotry-io/quota-protocol";
import {
  fetchAccountSummary,
  fetchAccountUsagePeriod,
  requestEmailSignInLink,
  unlinkIdentity,
} from "../src/lib/account-client.ts";
import { classifyAccountError } from "../src/lib/account-errors.ts";
import {
  ACTIVITY_DAYS,
  accountActivityPath,
  accountActivityRange,
  accountSummaryPath,
  clearStoredPeriods,
  clearStoredSummary,
} from "../src/lib/account-reads.ts";
import { SIGN_IN_PATH, signInHref } from "../src/lib/routes.ts";

test("asks for the summary in the calendar this browser keeps", () => {
  const url = new URL(accountSummaryPath("Asia/Singapore"), "https://quota.gotry.io");
  assert.equal(url.pathname, "/api/v6/account/summary");
  assert.equal(url.searchParams.get("tz"), "Asia/Singapore");
  assert.equal([...url.searchParams.keys()].join(","), "tz");
});

test("asks the activity chart for a year ending today", () => {
  const range = accountActivityRange(new Date("2026-08-15T08:10:00Z"));
  assert.equal(range.to, "2026-08-15");
  const days =
    (Date.parse(`${range.to}T00:00:00Z`) - Date.parse(`${range.from}T00:00:00Z`)) / 86_400_000 + 1;
  assert.equal(days, ACTIVITY_DAYS);

  const url = new URL(accountActivityPath(range), "https://quota.gotry.io");
  assert.equal(url.pathname, "/api/v6/account/usage/activity");
  assert.equal(url.searchParams.get("from"), range.from);
  assert.equal(url.searchParams.get("to"), range.to);
  assert.equal([...url.searchParams.keys()].sort().join(","), "from,to");
});

test("offers the last period ETag back and returns the cached body on 304", async () => {
  clearStoredPeriods();
  const query = {
    from: "2026-08-26",
    to: "2026-08-26",
    timezone: "Asia/Singapore",
    breakdown: true,
  };
  const body = {
    protocol_version: 6,
    request: { from: query.from, to: query.to, timezone: query.timezone },
    bounds: {
      start: "2026-08-25T16:00:00Z",
      end: "2026-08-26T16:00:00Z",
      grid: USAGE_HOUR_GRID_RULE,
    },
    totals: {
      total_tokens: 100,
      input_tokens: 80,
      output_tokens: 20,
      cache_read_input_tokens: 0,
      cache_write_input_tokens: 0,
      reasoning_tokens: 0,
      messages: 2,
    },
    cost: {
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
    },
    cache_saved: { amount_microusd: "0", status: "complete", unpriced_rows: 0 },
    days: [
      {
        date: "2026-08-26",
        totals: {
          total_tokens: 100,
          input_tokens: 80,
          output_tokens: 20,
          cache_read_input_tokens: 0,
          cache_write_input_tokens: 0,
          reasoning_tokens: 0,
          messages: 2,
        },
        cost: {
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
        },
        partial: false,
      },
    ],
    coverage: {
      partial: false,
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
  const requests: Array<Headers> = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (async (_input, init) => {
    const headers = new Headers(init?.headers);
    requests.push(headers);
    if (headers.get("If-None-Match") === '"period-1"') {
      return new Response(null, { status: 304, headers: { ETag: '"period-1"' } });
    }
    return new Response(JSON.stringify(body), {
      status: 200,
      headers: { "Content-Type": "application/json", ETag: '"period-1"' },
    });
  }) as typeof fetch;
  try {
    const first = await fetchAccountUsagePeriod(query);
    const second = await fetchAccountUsagePeriod(query);
    assert.equal(first.status, "ok");
    assert.equal(second.status, "ok");
    assert.equal(requests.length, 2);
    assert.equal(requests[0]?.get("If-None-Match"), null);
    assert.equal(requests[1]?.get("If-None-Match"), '"period-1"');
    if (first.status === "ok" && second.status === "ok") {
      assert.equal(second.period, first.period);
      assert.equal(second.period.totals.messages, 2);
    }
  } finally {
    globalThis.fetch = originalFetch;
    clearStoredPeriods();
  }
});

test("mails a sign-in or link request and treats 202 as accepted", async () => {
  const originalFetch = globalThis.fetch;
  const requests: Array<{ url: string; body: string }> = [];
  globalThis.fetch = (async (input, init) => {
    requests.push({ url: String(input), body: String(init?.body ?? "") });
    return new Response("{}", { status: 202 });
  }) as typeof fetch;
  try {
    assert.equal(
      await requestEmailSignInLink({ email: "person@example.test", returnTo: "/my" }),
      "accepted",
    );
    assert.equal(
      await requestEmailSignInLink({
        email: "person@example.test",
        returnTo: "/my/settings",
        intent: "link",
      }),
      "accepted",
    );
    assert.deepEqual(requests, [
      {
        url: "/api/auth/email/start",
        body: JSON.stringify({ email: "person@example.test", return_to: "/my" }),
      },
      {
        url: "/api/auth/email/start",
        body: JSON.stringify({
          email: "person@example.test",
          return_to: "/my/settings",
          intent: "link",
        }),
      },
    ]);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
test("unbinds a channel and treats the last one as a conflict", async () => {
  const originalFetch = globalThis.fetch;
  const requests: Array<{ url: string; method: string }> = [];
  const statuses = [204, 409, 403] as const;
  globalThis.fetch = (async (input, init) => {
    requests.push({ url: String(input), method: String(init?.method ?? "GET") });
    const status = statuses[requests.length - 1] ?? 500;
    return new Response(null, { status });
  }) as typeof fetch;
  try {
    assert.equal(await unlinkIdentity("github"), "ok");
    assert.equal(await unlinkIdentity("email"), "last_identity");
    const stale = await unlinkIdentity("apple", "/my/settings");
    assert.equal(
      stale === "ok" || stale === "last_identity" ? stale : stale.status,
      "recent_auth_required",
    );
    assert.deepEqual(requests, [
      { url: "/api/v2/account/identities/github", method: "DELETE" },
      { url: "/api/v2/account/identities/email", method: "DELETE" },
      { url: "/api/v2/account/identities/apple", method: "DELETE" },
    ]);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("classifies 401, a destructive 403, a plain 403, and 500", () => {
  const ended = classifyAccountError(new Response(null, { status: 401 }));
  assert.equal(ended.status, "session_ended");
  assert.deepEqual(ended.action, { type: "sign_in", href: signInHref() });

  const recent = classifyAccountError(new Response(null, { status: 403 }), {
    destructive: true,
    currentPath: "/my",
  });
  assert.equal(recent.status, "recent_auth_required");
  assert.deepEqual(recent.action, {
    type: "sign_in",
    href: `${SIGN_IN_PATH}?return_to=${encodeURIComponent("/my")}`,
  });

  const forbidden = classifyAccountError(new Response(null, { status: 403 }));
  assert.equal(forbidden.status, "forbidden");
  assert.equal(forbidden.action, null);

  const unavailable = classifyAccountError(new Response(null, { status: 500 }));
  assert.equal(unavailable.status, "unavailable");
  assert.equal(unavailable.action?.type, "retry");
});

function acceptedSummaryPayload(): unknown {
  const fixture = JSON.parse(
    readFileSync(
      join(
        dirname(fileURLToPath(import.meta.url)),
        "../../../packages/protocol/fixtures/wire-conformance.json",
      ),
      "utf8",
    ),
  ) as { contracts: { account_summary: { accepted: boolean; payload: unknown }[] } };
  const accepted = fixture.contracts.account_summary.find((item) => item.accepted);
  assert.ok(accepted, "wire-conformance.json has no accepted account_summary");
  return accepted.payload;
}

test("offers the last ETag back and returns the cached summary on 304", async () => {
  clearStoredSummary();
  const payload = acceptedSummaryPayload();
  const requests: Array<Headers> = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (async (_input, init) => {
    const headers = new Headers(init?.headers);
    requests.push(headers);
    if (headers.get("If-None-Match") === '"etag-1"') {
      return new Response(null, { status: 304, headers: { ETag: '"etag-1"' } });
    }
    return new Response(JSON.stringify(payload), {
      status: 200,
      headers: { "Content-Type": "application/json", ETag: '"etag-1"' },
    });
  }) as typeof fetch;
  try {
    const first = await fetchAccountSummary();
    const second = await fetchAccountSummary();
    assert.equal(first.status, "ok");
    assert.equal(second.status, "ok");
    assert.equal(requests.length, 2);
    assert.equal(requests[0]?.get("If-None-Match"), null);
    assert.equal(requests[1]?.get("If-None-Match"), '"etag-1"');
    if (first.status === "ok" && second.status === "ok") {
      assert.equal(second.summary, first.summary);
    }
  } finally {
    globalThis.fetch = originalFetch;
    clearStoredSummary();
  }
});
