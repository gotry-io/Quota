import assert from "node:assert/strict";
import test from "node:test";
import {
  accountReadFromSummary,
  accountUsagePeriod,
  screenshotAccountSummary,
} from "../e2e/account-fixture.ts";
import { parseAccountResponse } from "../src/lib/account-reads.ts";

test("screenshot account fixture matches the Account read", () => {
  const visual = parseAccountResponse(200, accountReadFromSummary(screenshotAccountSummary()));
  assert.equal(visual.status, "ok", visual.status === "ok" ? "" : visual.message);
  const smoke = parseAccountResponse(200, accountReadFromSummary());
  assert.equal(smoke.status, "ok", smoke.status === "ok" ? "" : smoke.message);
});

type PeriodBody = {
  request: { from: string; to: string };
  totals: { total_tokens: number; messages: number };
  cost: { amount_microusd: string | null };
  days: Array<{
    date: string;
    totals: { total_tokens: number; messages: number };
    cost: { amount_microusd: string | null };
  }>;
};

function asPeriod(body: unknown): PeriodBody {
  return body as PeriodBody;
}

test("period fixture parses for a preset and a custom range", () => {
  const today = asPeriod(
    accountUsagePeriod("2026-08-26", "2026-08-26", "Asia/Singapore", {
      breakdown: true,
    }),
  );
  assert.equal(today.request.from, "2026-08-26");
  const week = asPeriod(
    accountUsagePeriod("2026-08-20", "2026-08-26", "Asia/Singapore", {
      breakdown: true,
      summary: screenshotAccountSummary(),
    }),
  );
  assert.ok(Array.isArray(week.days));
});

test("period fixture days sum to totals and omit one date in a week", () => {
  const visual = screenshotAccountSummary();
  const today = asPeriod(
    accountUsagePeriod("2026-09-19", "2026-09-19", "UTC", {
      breakdown: true,
      summary: visual,
    }),
  );
  assert.equal(today.days.length, 1);
  assert.equal(today.days[0]?.date, "2026-09-19");
  assert.equal(today.days[0]?.totals.total_tokens, today.totals.total_tokens);
  assert.equal(today.days[0]?.cost.amount_microusd, today.cost.amount_microusd);

  const custom = asPeriod(
    accountUsagePeriod("2026-09-01", "2026-09-07", "UTC", {
      breakdown: true,
      summary: visual,
    }),
  );
  assert.equal(custom.days.length, 6);
  assert.equal(
    custom.days.some((day) => day.date === "2026-09-04"),
    false,
  );
  assert.equal(
    custom.days.reduce((sum, day) => sum + day.totals.total_tokens, 0),
    custom.totals.total_tokens,
  );
  assert.equal(
    custom.days.reduce((sum, day) => sum + Number(day.cost.amount_microusd ?? "0"), 0),
    Number(custom.cost.amount_microusd ?? "0"),
  );
});
