import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { isBalanceOnly, showsPercentMeter } from "@gotry-io/quota-model";
import {
  NO_READINGS_COPY,
  NO_RESET_TIME_COPY,
  NOT_CHECKED_COPY,
  lastReadingCopy,
  observationFreshnessCopy,
  relativeAge,
  resetCopy,
  showsNoResetTime,
  updatedCopy,
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
  reset: {
    name: string;
    seconds_until: number;
    now?: string;
    resets_at?: string;
    expected: string | null;
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
  assert.ok(fixture.reset.length > 1);
  for (const testCase of fixture.reset) {
    if (testCase.now !== undefined && testCase.resets_at !== undefined) {
      assert.equal(
        resetCopy(testCase.resets_at, new Date(testCase.now), timeZoneFromRfc3339(testCase.now)),
        testCase.expected,
        testCase.name,
      );
      continue;
    }
    const resetsAt = new Date(now.getTime() + testCase.seconds_until * 1000);
    assert.equal(resetCopy(resetsAt, now, "UTC"), testCase.expected, testCase.name);
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

test("classifies wallet windows as balance-only and metered windows as percent meters", () => {
  const wallet = { remaining_value: 12.5, used_percent: 0 };
  const metered = { remaining_value: 14.55, limit_value: 400, used_percent: 63.102 };

  assert.equal(isBalanceOnly(wallet), true);
  assert.equal(showsPercentMeter(wallet), false);
  assert.equal(isBalanceOnly(metered), false);
  assert.equal(showsPercentMeter(metered), true);

  assert.equal(showsNoResetTime(wallet), false);
  assert.equal(showsNoResetTime(metered), true);
});
