import { readFileSync } from "node:fs";
import { expect, type Page, test } from "@playwright/test";
import { csvCell, USAGE_EXPORT_CSV_HEADER } from "../src/lib/usage-export.ts";
import {
  accountActivity,
  accountActivityDay,
  accountReadFromSummary,
  accountSummary,
  accountUsagePeriod,
  mockAccountSettings,
  screenshotAccountRhythm,
} from "./account-fixture.ts";

async function mockV6(page: Page): Promise<void> {
  await mockAccountSettings(page);
  await page.route(
    (url) => new URL(url).pathname === "/api/v2/account",
    async (route) => {
      if (route.request().method() !== "GET") {
        await route.fallback();
        return;
      }
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify(accountReadFromSummary(accountSummary)),
      });
    },
  );
  await page.route("**/api/v6/**", async (route) => {
    const url = route.request().url();
    if (url.includes("/api/v6/account/summary")) {
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify(accountSummary),
      });
      return;
    }
    if (url.includes("/api/v6/account/usage/period")) {
      const asked = new URL(url);
      const from = asked.searchParams.get("from") ?? "2026-08-12";
      const to = asked.searchParams.get("to") ?? from;
      const timezone = asked.searchParams.get("timezone") ?? "UTC";
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify(
          accountUsagePeriod(from, to, timezone, {
            breakdown: asked.searchParams.get("breakdown") === "1",
            summary: accountSummary,
          }),
        ),
      });
      return;
    }
    if (url.includes("/api/v6/account/usage/activity")) {
      const asked = new URL(url);
      const from = asked.searchParams.get("from") ?? "2026-08-12";
      const to = asked.searchParams.get("to") ?? from;
      const detailed = asked.searchParams.get("detail") === "agents";
      const hours = asked.searchParams.get("detail") === "hours";
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify(
          detailed
            ? accountActivityDay(from)
            : hours
              ? screenshotAccountRhythm(from, to)
              : accountActivity,
        ),
      });
      return;
    }
    await route.fulfill({ status: 404, contentType: "application/json", body: "{}" });
  });
}

test("downloads a CSV for a custom range with a header and formula-safe cells", async ({
  page,
}) => {
  await mockV6(page);
  await page.goto("/my/usage?period=custom&from=2026-08-10&to=2026-08-12");
  await expect(page.getByRole("heading", { name: "Usage", exact: true })).toBeVisible();
  await expect(page.locator("#token-total")).not.toHaveText("—");

  expect(csvCell("=1+1")).toBe("'=1+1");

  await page.locator("#usage-export").click();
  const downloadPromise = page.waitForEvent("download");
  await page.getByRole("menuitem", { name: "CSV" }).click();
  const download = await downloadPromise;
  expect(download.suggestedFilename()).toBe("quota-usage-2026-08-10-2026-08-12.csv");
  const path = await download.path();
  expect(path).toBeTruthy();
  const csv = readFileSync(path as string, "utf8");
  const lines = csv.trimEnd().split("\n");
  expect(lines[0]).toBe(USAGE_EXPORT_CSV_HEADER);
  expect(csv).toContain("no usage recorded");
  const recorded = lines.find(
    (line) => line.startsWith("2026-08-10,") || line.startsWith("2026-08-12,"),
  );
  expect(recorded).toBeTruthy();
  expect(recorded?.includes('"')).toBe(false);
  for (const line of lines.slice(1)) {
    for (const cell of line.split(",")) {
      expect(cell === "" || !/^(?:[=+\-@]|\t|\r)/.test(cell)).toBe(true);
    }
  }
});
