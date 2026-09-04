import AxeBuilder from "@axe-core/playwright";
import { expect, type Page, test } from "@playwright/test";
import { accountActivity, accountActivityDay, accountSummary } from "./account-fixture.ts";

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
      const detailed = asked.searchParams.get("detail") === "agents";
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify(detailed ? accountActivityDay(from) : accountActivity),
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

test("switching account tabs does not refetch summary or activity", async ({ page }) => {
  let summaryRequests = 0;
  let activityListRequests = 0;
  await page.route("**/api/v6/**", async (route) => {
    const url = route.request().url();
    if (url.includes("/api/v6/account/summary")) {
      summaryRequests += 1;
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify(accountSummary),
      });
      return;
    }
    if (url.includes("/api/v6/account/usage/activity")) {
      const asked = new URL(url);
      if (asked.searchParams.get("detail") !== "agents") activityListRequests += 1;
      const from = asked.searchParams.get("from") ?? "2026-08-12";
      const detailed = asked.searchParams.get("detail") === "agents";
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify(detailed ? accountActivityDay(from) : accountActivity),
      });
      return;
    }
    await route.fulfill({ status: 404, contentType: "application/json", body: "{}" });
  });

  await page.goto("/my");
  const accountNav = page.getByRole("navigation", { name: "Account" });
  await expect(page.locator(".quota-card").filter({ hasText: "Codex" })).toBeVisible();

  await accountNav.getByRole("link", { name: "Usage" }).click();
  await expect(page.getByRole("heading", { name: "Usage", exact: true })).toBeVisible();
  await expect(page.getByRole("group", { name: "Usage activity by day" })).toBeVisible();

  await accountNav.getByRole("link", { name: "Devices" }).click();
  await expect(page.locator("#device-list")).toContainText("Studio");

  await accountNav.getByRole("link", { name: "Settings" }).click();
  await expect(page.getByRole("heading", { name: "Delete Account" })).toBeVisible();

  await accountNav.getByRole("link", { name: "Overview" }).click();
  await expect(page.locator(".quota-card").filter({ hasText: "Codex" })).toBeVisible();
  await expect(page.locator(".loading-block")).toHaveCount(0);

  await accountNav.getByRole("link", { name: "Usage" }).click();
  await expect(page.getByRole("heading", { name: "Usage", exact: true })).toBeVisible();
  await expect(page.getByRole("group", { name: "Usage activity by day" })).toBeVisible();
  await expect(page.locator(".loading-block")).toHaveCount(0);

  expect(summaryRequests).toBe(1);
  expect(activityListRequests).toBe(1);
});

test("/my shows overview, Usage period switch, and Devices", async ({ page }) => {
  await mockV6(page);
  await page.goto("/my");

  const header = page.getByRole("banner");
  const accountNav = header.getByRole("navigation", { name: "Account" });
  await expect(accountNav).toBeVisible();
  await expect(accountNav.getByRole("link", { name: "Overview" })).toHaveAttribute(
    "aria-current",
    "page",
  );
  await expect(page.getByRole("heading", { name: "Overview" })).toBeVisible();
  await expect(page.getByText(/Updated .* · \d+ devices? reporting/)).toBeVisible();
  await expect(page.getByRole("heading", { name: "Subscriptions" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Today" })).toBeVisible();
  await expect(page.locator(".quota-card").filter({ hasText: "Codex" })).toBeVisible();
  await expect(page.locator(".quota-card")).toContainText("Plus");
  await expect(page.locator("a.today-strip")).toHaveAttribute("href", "/my/usage?period=today");
  await expect(page.locator("a.devices-strip")).toBeVisible();
  await expect(page.locator("a.devices-strip")).toHaveAttribute("href", "/my/devices");

  const accountMenu = page.locator("#header-account-menu");
  await accountMenu.locator("summary").click();
  await expect(accountMenu.getByRole("link", { name: "Settings" })).toBeVisible();
  await expect(accountMenu.getByRole("button", { name: "Sign out" })).toBeVisible();
  await accountMenu.locator("summary").click();

  await accountNav.getByRole("link", { name: "Usage" }).click();
  await expect(page.getByRole("heading", { name: "Usage", exact: true })).toBeVisible();
  await expect(accountNav.getByRole("link", { name: "Usage" })).toHaveAttribute(
    "aria-current",
    "page",
  );
  const tokens = page.locator("#token-total");
  const cost = page.locator("#cost-total");
  const requests = page.locator("#request-total");
  await expect(tokens).not.toHaveText("—");
  await expect(cost).not.toHaveText("—");
  await expect(requests).not.toHaveText("—");

  const thirtyDayTokens = await tokens.innerText();
  await expect(page.getByRole("rowheader", { name: "gpt-fold-6" })).toHaveCount(0);
  await page.getByRole("button", { name: "Show 1 more" }).click();
  await expect(page.getByRole("button", { name: "Show 1 more" })).toHaveAttribute(
    "aria-expanded",
    "true",
  );
  await expect(page.getByRole("rowheader", { name: "gpt-fold-6" })).toBeVisible();
  await page.getByRole("button", { name: "Today" }).click();
  await expect(tokens).not.toHaveText(thirtyDayTokens);
  await expect(page).toHaveURL(/[?&]period=today(?:&|$)/);

  await accountNav.getByRole("link", { name: "Devices" }).click();
  await expect(page.getByRole("heading", { name: "Devices" })).toBeVisible();
  await expect(accountNav.getByRole("link", { name: "Devices" })).toHaveAttribute(
    "aria-current",
    "page",
  );
  await expect(page.locator("#device-list")).toContainText("Studio");
  await expect(page.getByRole("img", { name: "macOS" }).first()).toBeVisible();
  const deviceNames = page.locator("#device-list tbody th");
  await expect(deviceNames.nth(0)).toHaveText("Studio");
  await expect(deviceNames.nth(1)).toHaveText("Kitchen");
});

test("subscription card opens the detail page with windows and Reporting", async ({ page }) => {
  await mockV6(page);
  await page.goto("/my");
  await page.locator("a.quota-card-main").first().click();

  await expect(page).toHaveURL(/\/my\/subscriptions\/[a-f0-9]{12}$/);
  expect(page.url()).not.toContain("codex_account_1");
  expect(page.url()).not.toContain("device_1");
  await expect(page.getByRole("link", { name: "← Overview" })).toBeVisible();
  await expect(page.getByText("Weekly")).toBeVisible();
  await expect(page.getByText("Reporting")).toBeVisible();
  await expect(page.locator("body")).not.toContainText("codex_account_1");
  await expect(page.locator("body")).not.toContainText("device_1");

  const results = await new AxeBuilder({ page }).analyze();
  expect(seriousOrCritical(results.violations)).toEqual([]);
});

test("Usage is two columns at 1440 and stacked at 390", async ({ page }) => {
  await mockV6(page);
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/my/usage");
  await expect(page.locator(".usage-columns")).toBeVisible();
  await expect(page.locator("#token-total")).not.toHaveText("—");
  await expect(page.getByRole("group", { name: "Usage activity by day" })).toBeVisible();
  const headingRow = await page.evaluate(() => {
    const h1 = document.querySelector(".usage-heading h1")?.getBoundingClientRect();
    const tabs = document.querySelector(".period-tabs")?.getBoundingClientRect();
    if (!h1 || !tabs) return false;
    return Math.abs(h1.top - tabs.top) < 48;
  });
  expect(headingRow).toBe(true);
  const sideBySide = await page.evaluate(() => {
    const tree = document.querySelector(".usage-tree-panel")?.getBoundingClientRect();
    const activity = document.querySelector(".usage-activity-panel")?.getBoundingClientRect();
    if (!tree || !activity) return false;
    return activity.left >= tree.right - 1;
  });
  expect(sideBySide).toBe(true);

  await page.setViewportSize({ width: 390, height: 844 });
  const stacked = await page.evaluate(() => {
    const tree = document.querySelector(".usage-tree-panel")?.getBoundingClientRect();
    const activity = document.querySelector(".usage-activity-panel")?.getBoundingClientRect();
    if (!tree || !activity) return false;
    return activity.top >= tree.bottom - 1;
  });
  expect(stacked).toBe(true);
});

test("Settings groups Appearance, Notifications, Account, and Legal", async ({ page }) => {
  await mockV6(page);
  await page.goto("/my/settings");
  await expect(page.getByRole("heading", { name: "Appearance" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Notifications" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Account", exact: true })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Legal" })).toBeVisible();
  await expect(
    page.getByText(
      "Quota reminds you on your Mac and iPhone when a refresh brings new data. The web does not send notifications.",
    ),
  ).toBeVisible();
  await expect(
    page.locator(".settings-links").getByRole("link", { name: "Privacy" }),
  ).toHaveAttribute("href", "/privacy");
  await expect(
    page.locator(".settings-links").getByRole("link", { name: "Terms" }),
  ).toHaveAttribute("href", "/terms");
  await expect(
    page.locator(".settings-group").getByRole("button", { name: "Sign out" }),
  ).toBeVisible();
  await expect(page.getByRole("heading", { name: "Delete Account" })).toBeVisible();
});

test("activity grid is one tab stop and Enter opens the day tree", async ({ page }) => {
  await mockV6(page);
  await page.goto("/my/usage");
  await expect(page.getByRole("heading", { name: "Activity" })).toBeVisible();
  await expect(page.locator("button.usage-activity-cell[tabindex='0']")).toHaveCount(1);

  const rover = page.locator("button.usage-activity-cell[tabindex='0']");
  await rover.focus();
  await page.keyboard.press("Home");
  const start = await page
    .locator("button.usage-activity-cell[tabindex='0']")
    .getAttribute("data-date");
  await page.keyboard.press("ArrowRight");
  const moved = page.locator("button.usage-activity-cell[tabindex='0']");
  await expect(moved).not.toHaveAttribute("data-date", start ?? "");
  await page.keyboard.press("Enter");

  const panel = page.locator(".usage-activity-detail");
  await expect(panel.getByRole("button", { name: "Close" })).toBeVisible();
  await expect(page).toHaveURL(/[?&]day=\d{4}-\d{2}-\d{2}/);
  await expect(
    panel.getByRole("table", { name: "Usage by agent, provider, and model" }),
  ).toBeVisible();
  await expect(panel.getByRole("rowheader", { name: "Codex" })).toBeVisible();
  await expect(panel.getByRole("rowheader", { name: "gpt-5.6-sol" })).toBeVisible();
});

test("axe reports no serious or critical violations on /", async ({ page }) => {
  await page.goto("/");
  const results = await new AxeBuilder({ page }).analyze();
  expect(seriousOrCritical(results.violations)).toEqual([]);
});

for (const viewport of [
  { width: 390, height: 844 },
  { width: 1440, height: 900 },
] as const) {
  test(`landing does not overflow horizontally at ${viewport.width}`, async ({ page }) => {
    await page.setViewportSize(viewport);
    await page.goto("/");
    await expect(page.getByRole("heading", { name: "Know what you have left." })).toBeVisible();
    await expect(page.locator(".hero-preview img").first()).toBeVisible();
    await page.evaluate(async () => {
      await Promise.all(
        [...document.images].map((image) =>
          image.complete
            ? undefined
            : new Promise<void>((resolve) => {
                image.addEventListener("load", () => resolve(), { once: true });
                image.addEventListener("error", () => resolve(), { once: true });
              }),
        ),
      );
    });
    const fits = await page.evaluate(
      () => document.documentElement.scrollWidth <= window.innerWidth,
    );
    expect(fits).toBe(true);
  });
}

for (const path of ["/my", "/my/usage", "/my/devices", "/my/settings"] as const) {
  test(`axe reports no serious or critical violations on ${path}`, async ({ page }) => {
    await mockV6(page);
    await page.goto(path);
    await expect(page.getByRole("navigation", { name: "Account" })).toBeVisible();
    if (path === "/my") {
      await expect(page.locator(".quota-card")).toBeVisible();
    } else if (path === "/my/usage") {
      await expect(page.getByRole("heading", { name: "Usage", exact: true })).toBeVisible();
    } else if (path === "/my/devices") {
      await expect(page.locator("#device-list")).toBeVisible();
    } else {
      await expect(page.getByRole("heading", { name: "Delete Account" })).toBeVisible();
    }
    const results = await new AxeBuilder({ page }).analyze();
    expect(seriousOrCritical(results.violations)).toEqual([]);
  });
}
