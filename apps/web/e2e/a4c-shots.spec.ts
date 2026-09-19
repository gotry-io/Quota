import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, type Page, test } from "@playwright/test";
import {
  accountReadFromSummary,
  accountUsagePeriod,
  screenshotAccountActivity,
  screenshotAccountActivityDay,
  screenshotAccountRhythm,
  screenshotAccountSummary,
} from "./account-fixture.ts";

const enabled = process.env.SCREENSHOTS === "1";
const outputDir = join(dirname(fileURLToPath(import.meta.url)), "../../../../plan13/shots/w3-a4c");
const accountSummary = screenshotAccountSummary();

test.describe.configure({ mode: "serial" });
test.skip(!enabled, "gated by SCREENSHOTS=1");

mkdirSync(outputDir, { recursive: true });

async function mockV6(page: Page): Promise<void> {
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

async function shot(page: Page, name: string): Promise<void> {
  await page.screenshot({
    path: join(outputDir, name),
    fullPage: true,
    animations: "disabled",
  });
}

test.use({
  colorScheme: "light",
  viewport: { width: 1440, height: 900 },
  reducedMotion: "reduce",
});

test("Usage Today matches Overview Today", async ({ page }) => {
  await mockV6(page);
  await page.goto("/my");
  await expect(page.locator("a.today-strip")).toBeVisible();
  const overviewTokens = (await page.locator("a.today-strip strong").first().innerText()).trim();
  const overviewCost = (
    await page.locator("a.today-strip").locator("strong").nth(1).innerText()
  ).trim();

  await page.goto("/my/usage?period=day");
  await expect(page.getByRole("heading", { name: "Usage", exact: true })).toBeVisible();
  await expect(page.locator("#token-total")).toHaveText(overviewTokens);
  await expect(page.locator("#cost-total")).toHaveText(overviewCost);
  await shot(page, "usage-today-light.png");
});

test("Usage Last 7 days", async ({ page }) => {
  await mockV6(page);
  await page.goto("/my/usage?period=7d");
  await expect(page.locator("#token-total")).not.toHaveText("—");
  await shot(page, "usage-last-7-days-light.png");
});

test("Usage custom range", async ({ page }) => {
  await mockV6(page);
  await page.goto("/my/usage?period=custom&from=2026-09-01&to=2026-09-07");
  await expect(page.locator("#token-total")).not.toHaveText("—");
  await expect(page.locator("#usage-period-range")).toBeVisible();
  await shot(page, "usage-custom-light.png");
});

test("Usage budget row", async ({ page }) => {
  await mockV6(page);
  await page.addInitScript(() => {
    localStorage.setItem("quota.usage.budget.amount", "50");
    localStorage.setItem("quota.usage.budget.alerts", "on");
  });
  await page.goto("/my/usage");
  await expect(page.getByRole("heading", { name: "Monthly budget" })).toBeVisible();
  await expect(page.locator("#usage-budget-value")).toBeVisible();
  await page.getByRole("heading", { name: "Monthly budget" }).scrollIntoViewIfNeeded();
  await shot(page, "usage-budget-light.png");
});
