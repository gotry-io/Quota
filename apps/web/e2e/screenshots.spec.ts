import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, type Page, test } from "@playwright/test";
import {
  screenshotAccountActivity,
  screenshotAccountActivityDay,
  screenshotAccountSummary,
} from "./account-fixture.ts";

const enabled = process.env.SCREENSHOTS === "1";
const outputDir = join(dirname(fileURLToPath(import.meta.url)), "../static/screenshots");
const accountSummary = screenshotAccountSummary();

test.describe.configure({ mode: "serial" });
test.skip(!enabled, "gated by SCREENSHOTS=1");

mkdirSync(outputDir, { recursive: true });

async function mockV6(page: Page): Promise<void> {
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
    if (url.includes("/api/v6/account/usage/activity")) {
      const asked = new URL(url);
      const from = asked.searchParams.get("from") ?? "2026-08-12";
      const to = asked.searchParams.get("to") ?? from;
      const detailed = asked.searchParams.get("detail") === "agents";
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify(
          detailed ? screenshotAccountActivityDay(from) : screenshotAccountActivity(from, to),
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
    fullPage: false,
    animations: "disabled",
  });
}

const appearances = ["light", "dark"] as const;

for (const appearance of appearances) {
  test.describe(`${appearance} desktop`, () => {
    test.use({
      colorScheme: appearance,
      viewport: { width: 1440, height: 900 },
      reducedMotion: "reduce",
    });

    test(`overview ${appearance} desktop`, async ({ page }) => {
      await mockV6(page);
      await page.goto("/my");
      await expect(page.getByRole("heading", { name: "Subscriptions" })).toBeVisible();
      await expect(page.locator(".quota-card")).toHaveCount(3);
      await expect(page.getByText("octocat").first()).toBeVisible();
      await expect(page.getByText("pe***@example.com").first()).toBeVisible();
      await expect(page.getByText("Studio Mac").first()).toBeVisible();
      await expect(page.getByText("Kitchen Mac").first()).toBeVisible();
      await expect(page.getByText("68%").first()).toBeVisible();
      await expect(page.getByText("84%").first()).toBeVisible();
      await expect(page.getByText("53%").first()).toBeVisible();
      await expect(page.getByText("27%").first()).toBeVisible();
      await shot(page, `web-overview-${appearance}-desktop.png`);
    });

    test(`usage ${appearance} desktop`, async ({ page }) => {
      await mockV6(page);
      await page.goto("/my/usage");
      await expect(page.getByRole("heading", { name: "Totals" })).toBeVisible();
      await expect(page.locator("#token-total")).toHaveText("11.4M");
      await expect(page.locator("#cost-total")).toHaveText("$8.50");
      await expect(page.getByRole("button", { name: "Show 2 more" })).toBeVisible();
      await expect(page.getByRole("heading", { name: "Activity" })).toBeVisible();
      await expect(page.locator("button.usage-activity-cell").first()).toBeVisible();
      await shot(page, `web-usage-${appearance}-desktop.png`);
    });
  });

  test.describe(`${appearance} mobile`, () => {
    test.use({
      colorScheme: appearance,
      viewport: { width: 390, height: 844 },
      reducedMotion: "reduce",
    });

    test(`overview ${appearance} mobile`, async ({ page }) => {
      await mockV6(page);
      await page.goto("/my");
      await expect(page.getByRole("heading", { name: "Subscriptions" })).toBeVisible();
      await expect(page.locator(".quota-card")).toHaveCount(3);
      await expect(page.getByText("octocat").first()).toBeVisible();
      await expect(page.getByText("pe***@example.com").first()).toBeVisible();
      await expect(page.getByText("Studio Mac").first()).toBeVisible();
      await expect(page.getByText("Kitchen Mac").first()).toBeVisible();
      await shot(page, `web-overview-${appearance}-mobile.png`);
    });
  });
}
