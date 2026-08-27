import assert from "node:assert/strict";
import test from "node:test";
import {
  ACTIVITY_DAYS,
  accountActivityPath,
  accountActivityRange,
  accountSummaryPath,
} from "../src/lib/account-reads.ts";

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
