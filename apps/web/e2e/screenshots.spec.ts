import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, type Page, test } from "@playwright/test";
import {
  accountReadFromSummary,
  mockAccountSettings,
  screenshotAccountActivity,
  screenshotAccountActivityDay,
  screenshotAccountRhythm,
  screenshotAccountSummary,
  screenshotAccountUsagePeriod,
  screenshotQuotaHistory,
} from "./account-fixture.ts";

const enabled = process.env.SCREENSHOTS === "1";
const outputDir = join(dirname(fileURLToPath(import.meta.url)), "../static/screenshots");
const accountSummary = screenshotAccountSummary();

test.describe.configure({ mode: "serial" });
test.skip(!enabled, "gated by SCREENSHOTS=1");

mkdirSync(outputDir, { recursive: true });

async function mockV6(page: Page): Promise<void> {
  await mockAccountSettings(page);
  await page.route(
    (url) => new URL(url).pathname === "/api/v2/providers/status",
    async (route) => {
      if (route.request().method() !== "GET") {
        await route.fallback();
        return;
      }
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          providers: [
            {
              id: "claude",
              indicator: "minor",
              description: "Partial System Outage",
              checked_at: "2026-09-06T00:00:00Z",
            },
          ],
        }),
      });
    },
  );
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
          screenshotAccountUsagePeriod(from, to, timezone, {
            breakdown: asked.searchParams.get("breakdown") === "1",
            series: asked.searchParams.get("series") === "model",
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
    if (url.includes("/api/v6/account/quota-history")) {
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify(
          screenshotQuotaHistory(new URL(url).searchParams.get("provider") ?? ""),
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
      await page.goto("/my/quota");
      await expect(page.getByRole("heading", { name: "Subscriptions" })).toBeVisible();
      await expect(page.locator(".sub")).toHaveCount(6);
      await expect(page.getByText("Studio Mac").first()).toBeVisible();
      await shot(page, `web-overview-${appearance}-desktop.png`);
    });

    test(`usage ${appearance} desktop`, async ({ page }) => {
      await mockV6(page);
      await page.goto("/my");
      await expect(page.getByRole("table", { name: "Models in this period" })).toBeVisible();
      await expect(page.locator(".river path.band").first()).toBeVisible();
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
      await expect(page.getByRole("table", { name: "Models in this period" })).toBeVisible();
      await shot(page, `web-overview-${appearance}-mobile.png`);
    });
  });
}
