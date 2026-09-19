import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, it } from "vitest";
import {
  DEFAULT_USAGE_PERIOD,
  hiddenModelCount,
  nextUsagePeriod,
  previousUsagePeriod,
  USAGE_MODEL_FOLD_LIMIT,
  usagePeriodFromUrl,
  usagePeriodHref,
  usagePeriodRange,
  usagePeriodReadsFromSummary,
  usagePeriodSummaryKey,
  usagePeriodTitle,
  usageRangeDays,
} from "./usage-period.ts";

const base = "https://quota.gotry.io/my/usage";
/** A Sunday, so the week and the month both start before it. */
const today = new Date(2026, 8, 6, 12, 0, 0);

it("reads the period from the URL and defaults to the last 30 days", () => {
  expect(usagePeriodFromUrl(new URL(base))).toEqual(DEFAULT_USAGE_PERIOD);
  expect(usagePeriodFromUrl(new URL(`${base}?period=week&offset=2`))).toEqual({
    segment: "week",
    offset: 2,
  });
  expect(usagePeriodFromUrl(new URL(`${base}?period=all`))).toEqual({ segment: "all" });
  expect(
    usagePeriodFromUrl(new URL(`${base}?period=custom&from=2026-09-01&to=2026-09-03`)),
  ).toEqual({ segment: "custom", from: "2026-09-01", to: "2026-09-03" });
});

it("refuses a custom range that is inverted or is not a date", () => {
  expect(
    usagePeriodFromUrl(new URL(`${base}?period=custom&from=2026-09-04&to=2026-09-01`)),
  ).toEqual(DEFAULT_USAGE_PERIOD);
  expect(usagePeriodFromUrl(new URL(`${base}?period=custom&from=yesterday&to=today`))).toEqual(
    DEFAULT_USAGE_PERIOD,
  );
});

it("writes a period back into the URL so a refresh keeps it", () => {
  expect(usagePeriodHref(new URL(base), { segment: "day", offset: 0 })).toBe(
    "/my/usage?period=day",
  );
  expect(usagePeriodHref(new URL(base), { segment: "month", offset: 1 })).toBe(
    "/my/usage?period=month&offset=1",
  );
  const custom = usagePeriodHref(new URL(`${base}?period=week&offset=3`), {
    segment: "custom",
    from: "2026-09-01",
    to: "2026-09-03",
  });
  expect(custom).toBe("/my/usage?period=custom&from=2026-09-01&to=2026-09-03");
  expect(usagePeriodFromUrl(new URL(custom, base))).toEqual({
    segment: "custom",
    from: "2026-09-01",
    to: "2026-09-03",
  });
});

it("resolves each period against the browser's own calendar", () => {
  expect(usagePeriodRange({ segment: "day", offset: 0 }, today)).toEqual({
    from: "2026-09-06",
    to: "2026-09-06",
  });
  expect(usagePeriodRange({ segment: "day", offset: 1 }, today)).toEqual({
    from: "2026-09-05",
    to: "2026-09-05",
  });
  expect(usagePeriodRange({ segment: "week", offset: 0 }, today)).toEqual({
    from: "2026-08-31",
    to: "2026-09-06",
  });
  expect(usagePeriodRange({ segment: "week", offset: 1 }, today)).toEqual({
    from: "2026-08-24",
    to: "2026-08-30",
  });
  expect(usagePeriodRange({ segment: "month", offset: 0 }, today)).toEqual({
    from: "2026-09-01",
    to: "2026-09-30",
  });
  expect(usagePeriodRange({ segment: "month", offset: 1 }, today)).toEqual({
    from: "2026-08-01",
    to: "2026-08-31",
  });
  expect(usagePeriodRange({ segment: "7d" }, today)).toEqual({
    from: "2026-08-31",
    to: "2026-09-06",
  });
  expect(usagePeriodRange({ segment: "30d" }, today)).toEqual({
    from: "2026-08-08",
    to: "2026-09-06",
  });
  expect(usagePeriodRange({ segment: "all" }, today)).toBeNull();
});

it("steps a day, a week, and a month, and stops at the current one", () => {
  expect(previousUsagePeriod({ segment: "month", offset: 0 })).toEqual({
    segment: "month",
    offset: 1,
  });
  expect(nextUsagePeriod({ segment: "month", offset: 1 })).toEqual({
    segment: "month",
    offset: 0,
  });
  expect(nextUsagePeriod({ segment: "month", offset: 0 })).toBeNull();
  expect(previousUsagePeriod({ segment: "30d" })).toBeNull();
  expect(nextUsagePeriod({ segment: "custom", from: "2026-09-01", to: "2026-09-03" })).toBeNull();
});

it("names only the four periods the summary already folds", () => {
  expect(usagePeriodSummaryKey({ segment: "day", offset: 0 })).toBe("today");
  expect(usagePeriodSummaryKey({ segment: "day", offset: 1 })).toBeNull();
  expect(usagePeriodSummaryKey({ segment: "7d" })).toBe("last_7_days");
  expect(usagePeriodSummaryKey({ segment: "30d" })).toBe("last_30_days");
  expect(usagePeriodSummaryKey({ segment: "all" })).toBe("all");
  expect(usagePeriodSummaryKey({ segment: "week", offset: 0 })).toBeNull();
  expect(usagePeriodSummaryKey({ segment: "month", offset: 0 })).toBeNull();
});

it("reads only All from the summary; presets are the same period read as custom", () => {
  expect(usagePeriodReadsFromSummary({ segment: "all" })).toBe(true);
  expect(usagePeriodReadsFromSummary({ segment: "day", offset: 0 })).toBe(false);
  expect(usagePeriodReadsFromSummary({ segment: "7d" })).toBe(false);
  expect(usagePeriodReadsFromSummary({ segment: "30d" })).toBe(false);
  expect(usagePeriodReadsFromSummary({ segment: "week", offset: 0 })).toBe(false);
  expect(usagePeriodReadsFromSummary({ segment: "month", offset: 0 })).toBe(false);
  expect(
    usagePeriodReadsFromSummary({ segment: "custom", from: "2026-08-26", to: "2026-08-26" }),
  ).toBe(false);
});

it("computes the same from/to the period fixture names for presets", () => {
  const fixture = JSON.parse(
    readFileSync(
      join(
        dirname(fileURLToPath(import.meta.url)),
        "../../../../packages/protocol/fixtures/usage-period-conformance.json",
      ),
      "utf8",
    ),
  ) as {
    cases: Array<{
      name: string;
      summary_presets?: Array<{ key: string; from: string; to: string }>;
    }>;
  };
  const preset = fixture.cases.find((testCase) => testCase.name === "preset_equals_custom");
  const presets = preset?.summary_presets;
  if (!presets) throw new Error("usage-period-conformance.json is missing preset_equals_custom");
  const todayPreset = presets.find((item) => item.key === "today");
  if (!todayPreset) throw new Error("preset_equals_custom is missing today");
  const [year, month, day] = todayPreset.from.split("-").map(Number);
  const today = new Date(year as number, (month as number) - 1, day as number, 10, 0, 0);
  const selection = {
    today: { segment: "day" as const, offset: 0 },
    last_7_days: { segment: "7d" as const },
    last_30_days: { segment: "30d" as const },
  };
  for (const item of presets) {
    const chosen = selection[item.key as keyof typeof selection];
    expect(usagePeriodRange(chosen, today)).toEqual({ from: item.from, to: item.to });
    expect(usagePeriodRange({ segment: "custom", from: item.from, to: item.to }, today)).toEqual({
      from: item.from,
      to: item.to,
    });
  }
});

it("titles a period with the range it covers", () => {
  expect(usagePeriodTitle({ segment: "day", offset: 0 }, today)).toContain("2026");
  expect(usagePeriodTitle({ segment: "all" }, today)).toBe("Everything kept");
  const week = usagePeriodTitle({ segment: "week", offset: 0 }, today);
  expect(week).toContain("–");
});

it("counts the days a range covers, both ends included", () => {
  expect(usageRangeDays({ from: "2026-09-01", to: "2026-09-01" })).toBe(1);
  expect(usageRangeDays({ from: "2026-09-01", to: "2026-09-30" })).toBe(30);
});

it("hides models past the fold limit", () => {
  expect(USAGE_MODEL_FOLD_LIMIT).toBe(5);
  expect(hiddenModelCount(5)).toBe(0);
  expect(hiddenModelCount(6)).toBe(1);
});
