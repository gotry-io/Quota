import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  formatRemaining,
  isAmountOfLimit,
  isBalanceOnly,
  quotaPace,
  showsPercentMeter,
} from "@gotry-io/quota-model";
import {
  NO_READINGS_COPY,
  NO_RESET_TIME_COPY,
  NOT_CHECKED_COPY,
  formatQuotaRemaining,
  formatUtcDateRange,
  lastReadingCopy,
  observationFreshnessCopy,
  paceCopy,
  relativeAge,
  resetCopy,
  showsNoResetTime,
  updatedCopy,
  usageModelDisplayName,
} from "../src/lib/format.ts";

/**
 * QuotaBar and the iOS app say these phrases too. Both runtimes answer the same file, so a
 * phrase one of them changes cannot quietly drift from the other.
 */
const fixture = JSON.parse(
  readFileSync(
    join(
      dirname(fileURLToPath(import.meta.url)),
      "../../../packages/protocol/fixtures/freshness-copy-conformance.json",
    ),
    "utf8",
  ),
) as {
  phrases: Record<string, string>;
  age: { name: string; age_seconds: number; expected: string }[];
  observation: { name: string; status: string; age_seconds: number; expected: string }[];
  missing_reset: {
    name: string;
    remaining_percent: number;
    shows_percent_meter: boolean;
    expected: boolean;
  }[];
  device: { name: string; age_seconds: number | null; expected: string }[];
};

const resetFixture = JSON.parse(
  readFileSync(
    join(
      dirname(fileURLToPath(import.meta.url)),
      "../../../packages/protocol/fixtures/reset-copy-conformance.json",
    ),
    "utf8",
  ),
) as {
  cases: {
    name: string;
    now: string;
    resets_at: string;
    relative: string | null;
    absolute: string | null;
  }[];
};

const remainingFixture = JSON.parse(
  readFileSync(
    join(
      dirname(fileURLToPath(import.meta.url)),
      "../../../packages/protocol/fixtures/remaining-copy-conformance.json",
    ),
    "utf8",
  ),
) as {
  cases: {
    name: string;
    window: {
      id?: string;
      used_percent: number;
      remaining_value?: number;
      limit_value?: number;
      value_unit?: string;
    };
    expected: string;
    shows_percent_meter: boolean;
    is_balance_only: boolean;
    is_amount_of_limit: boolean;
  }[];
};

const now = new Date("2026-08-25T12:00:00Z");

function instant(ageSeconds: number): string {
  return new Date(now.getTime() - ageSeconds * 1000).toISOString();
}

/** Map an RFC 3339 offset to an IANA zone `Intl` can format. `Etc/GMT` signs are inverted. */
function timeZoneFromRfc3339(value: string): string {
  if (value.endsWith("Z")) return "UTC";
  const match = value.match(/([+-])(\d{2}):(\d{2})$/);
  if (match === null) throw new Error(`reset fixture timestamp has no offset: ${value}`);
  if (match[3] !== "00") {
    throw new Error(`reset fixture timestamps use whole-hour offsets: ${value}`);
  }
  const hours = Number(match[2]);
  if (hours === 0) return "UTC";
  const inverted = match[1] === "-" ? "+" : "-";
  return `Etc/GMT${inverted}${hours}`;
}

test("named freshness phrases match the shared fixture", () => {
  assert.equal(NO_RESET_TIME_COPY, fixture.phrases.no_reset_time);
  assert.equal(NOT_CHECKED_COPY, fixture.phrases.not_checked);
  assert.equal(NO_READINGS_COPY, fixture.phrases.no_readings);
  assert.equal(updatedCopy(null, now), fixture.phrases.not_checked);
});

test("relative age matches the shared fixture", () => {
  assert.ok(fixture.age.length > 1);
  for (const testCase of fixture.age) {
    assert.equal(relativeAge(instant(testCase.age_seconds), now), testCase.expected, testCase.name);
  }
});

test("observation lines match the shared fixture", () => {
  assert.ok(fixture.observation.length > 1);
  for (const testCase of fixture.observation) {
    assert.equal(
      observationFreshnessCopy(testCase.status, instant(testCase.age_seconds), now),
      testCase.expected,
      testCase.name,
    );
  }
});

test("device lines match the shared fixture", () => {
  assert.ok(fixture.device.length > 1);
  for (const testCase of fixture.device) {
    const value = testCase.age_seconds === null ? null : instant(testCase.age_seconds);
    assert.equal(lastReadingCopy(value, now), testCase.expected, testCase.name);
  }
});

test("reset copy matches the shared fixture", () => {
  assert.ok(resetFixture.cases.length > 1);
  for (const testCase of resetFixture.cases) {
    const zone = timeZoneFromRfc3339(testCase.now);
    const nowAt = new Date(testCase.now);
    assert.equal(
      resetCopy(testCase.resets_at, nowAt, zone, "relative"),
      testCase.relative,
      `${testCase.name} relative`,
    );
    assert.equal(
      resetCopy(testCase.resets_at, nowAt, zone, "absolute"),
      testCase.absolute,
      `${testCase.name} absolute`,
    );
  }
});

test("remaining copy matches the shared fixture", () => {
  assert.ok(remainingFixture.cases.length > 1);
  for (const testCase of remainingFixture.cases) {
    assert.equal(formatRemaining(testCase.window), testCase.expected, `${testCase.name} copy`);
    assert.equal(
      formatQuotaRemaining(testCase.window),
      testCase.expected,
      `${testCase.name} web copy`,
    );
    assert.equal(
      showsPercentMeter(testCase.window),
      testCase.shows_percent_meter,
      `${testCase.name} meter`,
    );
    assert.equal(
      isBalanceOnly(testCase.window),
      testCase.is_balance_only,
      `${testCase.name} balance`,
    );
    assert.equal(
      isAmountOfLimit(testCase.window),
      testCase.is_amount_of_limit,
      `${testCase.name} amount`,
    );
  }
});

test("missing reset display matches the shared fixture", () => {
  assert.ok(fixture.missing_reset.length > 1);
  for (const testCase of fixture.missing_reset) {
    assert.equal(
      showsNoResetTime(testCase.remaining_percent, testCase.shows_percent_meter),
      testCase.expected,
      testCase.name,
    );
  }
});

test("formats a UTC date range in English", () => {
  assert.equal(formatUtcDateRange("2025-09-05", "2026-09-04"), "Sep 5, 2025 – Sep 4, 2026");
});

test("names the overflow model leaf Other", () => {
  assert.equal(usageModelDisplayName("other"), "Other");
  assert.equal(usageModelDisplayName("gpt-5"), "gpt-5");
});

test("classifies wallet windows as balance-only and metered windows as percent meters", () => {
  const wallet = { remaining_value: 12.5, used_percent: 0 };
  const metered = { remaining_value: 14.55, limit_value: 400, used_percent: 63.102 };

  assert.equal(isBalanceOnly(wallet), true);
  assert.equal(showsPercentMeter(wallet), false);
  assert.equal(isBalanceOnly(metered), false);
  assert.equal(showsPercentMeter(metered), true);

  assert.equal(showsNoResetTime(wallet), false);
  assert.equal(showsNoResetTime(metered), true);

  const extra = {
    used_percent: 12.5,
    remaining_value: 87.5,
    limit_value: 100,
    value_unit: "usd",
  };
  assert.equal(showsPercentMeter(extra), false);
  assert.equal(showsNoResetTime(extra), false);
});

/**
 * The pace line is the same sentence on the website, in QuotaBar, and in the iOS app.
 * `QuotaPaceCopy` answers this file too, so a phrase one of them changes fails the other.
 */
const paceFixture = JSON.parse(
  readFileSync(
    join(
      dirname(fileURLToPath(import.meta.url)),
      "../../../packages/protocol/fixtures/quota-pace-conformance.json",
    ),
    "utf8",
  ),
) as {
  cases: {
    name: string;
    now: string;
    window: { used_percent: number; resets_at?: string; duration_seconds?: number };
    expected_copy: string | null;
  }[];
};

test("pace copy matches the shared fixture", () => {
  assert.ok(paceFixture.cases.length >= 12);
  for (const testCase of paceFixture.cases) {
    const pace = quotaPace(testCase.window, new Date(testCase.now));
    assert.equal(paceCopy(pace, testCase.window.resets_at), testCase.expected_copy, testCase.name);
  }
});
