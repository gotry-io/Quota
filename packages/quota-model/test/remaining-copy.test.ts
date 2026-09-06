import remainingCopyJson from "../../protocol/fixtures/remaining-copy-conformance.json" with {
  type: "json",
};
import resetCopyJson from "../../protocol/fixtures/reset-copy-conformance.json" with {
  type: "json",
};
import { describe, expect, it } from "vitest";
import {
  AMOUNT_OF_LIMIT_PERCENT_TOLERANCE,
  formatRemaining,
  isAmountOfLimit,
  isBalanceOnly,
  remainingPercent,
  resetCopy,
  showsPercentMeter,
} from "../src/index.ts";

type RemainingCase = {
  name: string;
  window: {
    used_percent: number;
    remaining_value?: number;
    limit_value?: number;
    value_unit?: string;
  };
  expected: string;
  shows_percent_meter: boolean;
  is_balance_only: boolean;
  is_amount_of_limit: boolean;
};

type ResetCase = {
  name: string;
  now: string;
  resets_at: string;
  relative: string | null;
  absolute: string | null;
};

const remainingCopy = remainingCopyJson as {
  amount_of_limit_percent_tolerance: number;
  cases: RemainingCase[];
};

const resetCopyFixture = resetCopyJson as { cases: ResetCase[] };

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

describe("remaining copy conformance", () => {
  it("pins the amount-of-limit tolerance", () => {
    expect(AMOUNT_OF_LIMIT_PERCENT_TOLERANCE).toBe(remainingCopy.amount_of_limit_percent_tolerance);
  });

  it("answers every remaining-copy fixture case", () => {
    expect(remainingCopy.cases.length).toBeGreaterThan(1);
    for (const testCase of remainingCopy.cases) {
      expect(formatRemaining(testCase.window), `${testCase.name} copy`).toBe(testCase.expected);
      expect(showsPercentMeter(testCase.window), `${testCase.name} meter`).toBe(
        testCase.shows_percent_meter,
      );
      expect(isBalanceOnly(testCase.window), `${testCase.name} balance`).toBe(
        testCase.is_balance_only,
      );
      expect(isAmountOfLimit(testCase.window), `${testCase.name} amount`).toBe(
        testCase.is_amount_of_limit,
      );
      expect(remainingPercent(testCase.window.used_percent)).toBeGreaterThanOrEqual(0);
    }
  });
});

describe("reset copy conformance", () => {
  it("answers relative and absolute for every reset-copy fixture case", () => {
    expect(resetCopyFixture.cases.length).toBeGreaterThan(1);
    for (const testCase of resetCopyFixture.cases) {
      const zone = timeZoneFromRfc3339(testCase.now);
      const now = new Date(testCase.now);
      expect(
        resetCopy(testCase.resets_at, now, zone, "relative"),
        `${testCase.name} relative`,
      ).toBe(testCase.relative);
      expect(
        resetCopy(testCase.resets_at, now, zone, "absolute"),
        `${testCase.name} absolute`,
      ).toBe(testCase.absolute);
    }
  });
});
