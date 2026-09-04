import AxeBuilder from "@axe-core/playwright";
import { expect, test, type Page } from "@playwright/test";
import { accountActivity, accountSummary } from "./account-fixture.ts";

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
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify(accountActivity),
      });
      return;
    }
    await route.fulfill({ status: 404, contentType: "application/json", body: "{}" });
  });
}

function seriousOrCritical(
  violations: Array<{
    id: string;
    impact?: string | null;
    help: string;
    nodes: Array<{ html: string; target: string[] }>;
  }>,
) {
  return violations
    .filter((violation) => violation.impact === "serious" || violation.impact === "critical")
    .map((violation) => ({
      id: violation.id,
      impact: violation.impact,
      help: violation.help,
      nodes: violation.nodes.map((node) => ({ html: node.html, target: node.target })),
    }));
}

test("/my shows a subscription card, Usage totals, period switch, and Devices", async ({
  page,
}) => {
  await mockV6(page);
  await page.goto("/my");

  await expect(page.getByRole("heading", { name: "Subscriptions" })).toBeVisible();
  await expect(page.locator(".quota-card").filter({ hasText: "Codex" })).toBeVisible();
  await expect(page.locator(".quota-card")).toContainText("Plus");

  await expect(page.getByRole("heading", { name: "Totals" })).toBeVisible();
  const tokens = page.locator("#token-total");
  const cost = page.locator("#cost-total");
  await expect(tokens).not.toHaveText("—");
  await expect(cost).not.toHaveText("—");

  const thirtyDayTokens = await tokens.innerText();
  await page.getByRole("button", { name: "Today" }).click();
  await expect(tokens).not.toHaveText(thirtyDayTokens);

  await expect(page.getByRole("heading", { name: "Devices" })).toBeVisible();
  await expect(page.locator("#device-list")).toContainText("Studio");
  await expect(page.locator("#device-list")).toContainText("macOS");
});

test("axe reports no serious or critical violations on /", async ({ page }) => {
  await page.goto("/");
  const results = await new AxeBuilder({ page }).analyze();
  expect(seriousOrCritical(results.violations)).toEqual([]);
});

test("axe reports no serious or critical violations on /my", async ({ page }) => {
  await mockV6(page);
  await page.goto("/my");
  await expect(page.locator(".quota-card")).toBeVisible();
  const results = await new AxeBuilder({ page }).analyze();
  expect(seriousOrCritical(results.violations)).toEqual([]);
});
