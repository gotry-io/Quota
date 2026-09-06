import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  fetchAccountActivity,
  fetchAccountSummary,
  requestEmailSignInLink,
} from "../src/lib/account-client.ts";
import { classifyAccountError } from "../src/lib/account-errors.ts";
import {
  ACTIVITY_DAYS,
  accountActivityPath,
  accountActivityRange,
  accountSummaryPath,
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

test("asks a single UTC day for its agent tree", async () => {
  const range = { from: "2026-08-12", to: "2026-08-12" };
  const url = new URL(accountActivityPath(range, "agents"), "https://quota.gotry.io");
  assert.equal(url.pathname, "/api/v6/account/usage/activity");
  assert.equal(url.searchParams.get("from"), "2026-08-12");
  assert.equal(url.searchParams.get("to"), "2026-08-12");
  assert.equal(url.searchParams.get("detail"), "agents");
  assert.equal([...url.searchParams.keys()].sort().join(","), "detail,from,to");

  let requested = "";
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (async (input) => {
    requested = String(input);
    return new Response(JSON.stringify({ protocol_version: 6, days: [] }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }) as typeof fetch;
  try {
    const result = await fetchAccountActivity(range, "agents");
    assert.equal(result.status, "ok");
    const asked = new URL(requested, "https://quota.gotry.io");
    assert.equal(asked.searchParams.get("from"), "2026-08-12");
    assert.equal(asked.searchParams.get("to"), "2026-08-12");
    assert.equal(asked.searchParams.get("detail"), "agents");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("asks Relay to mail a sign-in link and treats 202 as accepted", async () => {
  const originalFetch = globalThis.fetch;
  let requested = "";
  let body = "";
  globalThis.fetch = (async (input, init) => {
    requested = String(input);
    body = String(init?.body ?? "");
    return new Response("{}", { status: 202 });
  }) as typeof fetch;
  try {
    const result = await requestEmailSignInLink({
      email: "person@example.test",
      returnTo: "/my",
    });
    assert.equal(result, "accepted");
    assert.equal(requested, "/api/auth/email/start");
    assert.equal(body, JSON.stringify({ email: "person@example.test", return_to: "/my" }));
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("classifies 401 as a session that ended", () => {
  const error = classifyAccountError(new Response(null, { status: 401 }));
  assert.equal(error.status, "session_ended");
  assert.equal(error.message, "Your session ended. Sign in again.");
  assert.equal(error.action?.type, "sign_in");
  if (error.action?.type === "sign_in") {
    assert.equal(error.action.href, signInHref());
  }
});

test("classifies a destructive 403 as recent authentication", () => {
  const error = classifyAccountError(new Response(null, { status: 403 }), {
    destructive: true,
    currentPath: "/my",
  });
  assert.equal(error.status, "recent_auth_required");
  assert.equal(error.message, "Sign in again to confirm this change.");
  assert.equal(error.action?.type, "sign_in");
  if (error.action?.type === "sign_in") {
    assert.equal(error.action.href, `${SIGN_IN_PATH}?return_to=${encodeURIComponent("/my")}`);
  }
});

test("classifies a non-destructive 403 as forbidden", () => {
  const error = classifyAccountError(new Response(null, { status: 403 }));
  assert.equal(error.status, "forbidden");
  assert.equal(error.message, "You don't have permission to do that.");
  assert.equal(error.action, null);
});

test("classifies 500 as unavailable", () => {
  const error = classifyAccountError(new Response(null, { status: 500 }));
  assert.equal(error.status, "unavailable");
  assert.equal(error.message, "Quota couldn't load this. Retry.");
  assert.equal(error.action?.type, "retry");
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
