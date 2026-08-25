import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  NO_READINGS_COPY,
  NO_RESET_TIME_COPY,
  NOT_CHECKED_COPY,
  lastReadingCopy,
  observationFreshnessCopy,
  relativeAge,
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
  device: { name: string; age_seconds: number | null; expected: string }[];
};

const now = new Date("2026-08-25T12:00:00Z");

function instant(ageSeconds: number): string {
  return new Date(now.getTime() - ageSeconds * 1000).toISOString();
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
