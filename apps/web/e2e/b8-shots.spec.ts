import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, type Page, test } from "@playwright/test";
import {
  accountReadFromSummary,
  accountUsagePeriod,
  mockAccountSettings,
  screenshotAccountActivity,
  screenshotAccountActivityDay,
  screenshotAccountRhythm,
  screenshotAccountSummary,
} from "./account-fixture.ts";

const enabled = process.env.SCREENSHOTS === "1";
const outputDir = join(dirname(fileURLToPath(import.meta.url)), "../../../../plan13/shots/w5-b8");
const accountSummary = screenshotAccountSummary();

test.describe.configure({ mode: "serial" });
test.skip(!enabled, "gated by SCREENSHOTS=1");

mkdirSync(outputDir, { recursive: true });

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
            ? screenshotAccountActivityDay(from)
            : hours
              ? screenshotAccountRhythm(from, to)
              : screenshotAccountActivity(from, to),
        ),
      });
      return;
    }
    await route.fulfill({ status: 404, contentType: "application/json", body: "{}" });
  });
}

test.use({
  colorScheme: "light",
  viewport: { width: 1440, height: 900 },
  reducedMotion: "reduce",
});

test("Usage Export menu open", async ({ page }) => {
  await mockV6(page);
  await page.goto("/my/usage");
  await expect(page.getByRole("heading", { name: "Usage", exact: true })).toBeVisible();
  await expect(page.locator("#token-total")).not.toHaveText("—");
  await page.locator("#usage-export").click();
  await expect(page.getByRole("menuitem", { name: "CSV" })).toBeVisible();
  await page.screenshot({
    path: join(outputDir, "web-usage-export-menu-light.png"),
    fullPage: true,
    animations: "disabled",
  });
});
