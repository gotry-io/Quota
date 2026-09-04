import { expect, it } from "vitest";
import {
  DEFAULT_USAGE_PERIOD_QUERY,
  hiddenModelCount,
  USAGE_MODEL_FOLD_LIMIT,
  usagePeriodFromQuery,
  usagePeriodHref,
  usagePeriodKey,
} from "./usage-period.ts";

it("reads the period query and defaults to 30 Days", () => {
  expect(usagePeriodFromQuery(null)).toBe(DEFAULT_USAGE_PERIOD_QUERY);
  expect(usagePeriodFromQuery("today")).toBe("today");
  expect(usagePeriodFromQuery("7d")).toBe("7d");
  expect(usagePeriodFromQuery("30d")).toBe("30d");
  expect(usagePeriodFromQuery("all")).toBe("all");
  expect(usagePeriodFromQuery("last_30_days")).toBe("30d");
});

it("maps query values onto the summary period keys", () => {
  expect(usagePeriodKey("today")).toBe("today");
  expect(usagePeriodKey("7d")).toBe("last_7_days");
  expect(usagePeriodKey("30d")).toBe("last_30_days");
  expect(usagePeriodKey("all")).toBe("all");
});

it("writes ?period= so a refresh keeps the selected tab", () => {
  const href = usagePeriodHref(new URL("https://quota.gotry.io/my/usage"), "today");
  expect(href).toBe("/my/usage?period=today");
  expect(
    usagePeriodFromQuery(new URL(href, "https://quota.gotry.io").searchParams.get("period")),
  ).toBe("today");
});

it("hides models past the fold limit", () => {
  expect(USAGE_MODEL_FOLD_LIMIT).toBe(5);
  expect(hiddenModelCount(5)).toBe(0);
  expect(hiddenModelCount(6)).toBe(1);
});
