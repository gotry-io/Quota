import AxeBuilder from "@axe-core/playwright";
import { expect, type Page, test } from "@playwright/test";
import {
  accountActivity,
  accountActivityDay,
  accountReadFromSummary,
  accountSummary,
  accountUsagePeriod,
  mockAccountSettings,
  screenshotAccountRhythm,
} from "./account-fixture.ts";

async function mockAccountRead(page: Page, summary: unknown = accountSummary): Promise<void> {
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
        body: JSON.stringify(accountReadFromSummary(summary)),
      });
    },
  );
}

async function mockV6(page: Page, summary: unknown = accountSummary): Promise<void> {
  await mockAccountRead(page, summary);
  await mockAccountSettings(page);
  await page.route("**/api/v6/**", async (route) => {
    const url = route.request().url();
    if (url.includes("/api/v6/account/summary")) {
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify(summary),
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
            summary: summary as typeof accountSummary,
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

test("Overview does not prefetch activity", async ({ page }) => {
  let activityListRequests = 0;
  let periodRequests = 0;
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
      periodRequests += 1;
      await route.fulfill({ status: 404, contentType: "application/json", body: "{}" });
      return;
    }
    if (url.includes("/api/v6/account/usage/activity")) {
      const asked = new URL(url);
      if (!asked.searchParams.get("detail")) activityListRequests += 1;
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify(accountActivity),
      });
      return;
    }
    await route.fulfill({ status: 404, contentType: "application/json", body: "{}" });
  });

  await page.goto("/my");
  await expect(page.locator(".quota-card").filter({ hasText: "Codex" })).toBeVisible();
  expect(activityListRequests).toBe(0);
  expect(periodRequests).toBe(0);
});

test("switching account tabs does not refetch summary or activity", async ({ page }) => {
  let summaryRequests = 0;
  let activityListRequests = 0;
  await mockAccountRead(page);
  await mockAccountSettings(page);
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
      if (!asked.searchParams.get("detail")) activityListRequests += 1;
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
  await expect(page.getByText(/Latest quota updated .* · \d+ devices? reporting/)).toBeVisible();
  await expect(page.getByRole("heading", { name: "Subscriptions" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Today" })).toBeVisible();
  await expect(page.locator(".quota-card").filter({ hasText: "Codex" })).toBeVisible();
  await expect(page.locator(".quota-card")).toContainText("Plus");
  await expect(page.locator("a.today-strip")).toHaveAttribute("href", "/my/usage?period=day");
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
  const messages = page.locator("#message-total");
  await expect(tokens).not.toHaveText("—");
  await expect(cost).not.toHaveText("—");
  await expect(messages).not.toHaveText("—");
  await expect(page.getByText("Messages", { exact: true })).toBeVisible();

  const thirtyDayTokens = await tokens.innerText();
  await expect(page.getByRole("rowheader", { name: "gpt-fold-6" })).toHaveCount(0);
  await page.getByRole("button", { name: "Show 1 more" }).click();
  const fewer = page.getByRole("button", { name: "Show fewer" });
  await expect(fewer).toHaveAttribute("aria-expanded", "true");
  await expect(page.getByRole("rowheader", { name: "gpt-fold-6" })).toBeVisible();
  await fewer.click();
  await expect(page.getByRole("button", { name: "Show 1 more" })).toHaveAttribute(
    "aria-expanded",
    "false",
  );
  await page.getByRole("button", { name: "Today", exact: true }).click();
  await expect(tokens).not.toHaveText(thirtyDayTokens);
  await expect(page).toHaveURL(/[?&]period=day(?:&|$)/);

  await accountNav.getByRole("link", { name: "Devices" }).click();
  await expect(page.getByRole("heading", { name: "Devices" })).toBeVisible();
  await expect(accountNav.getByRole("link", { name: "Devices" })).toHaveAttribute(
    "aria-current",
    "page",
  );
  await expect(page.locator("#device-list")).toContainText("Studio");
  await expect(page.getByRole("img", { name: "macOS" }).first()).toBeVisible();
  await expect(page.getByRole("columnheader", { name: "Last contact" })).toBeVisible();
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

function accountReadWithIdentities(
  identities: { provider: string; label: string; linked_at: string }[],
): ReturnType<typeof accountReadFromSummary> {
  return { ...accountReadFromSummary(), identities };
}

async function mockAccountIdentities(
  page: Page,
  identities: { provider: string; label: string; linked_at: string }[],
): Promise<void> {
  await mockV6(page);
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
        body: JSON.stringify(accountReadWithIdentities(identities)),
      });
    },
  );
}

test("Settings shows a one-time notice when a link was already taken", async ({ page }) => {
  await mockV6(page);
  await page.goto("/my/settings?linked=taken");
  await expect(
    page.getByRole("alert").filter({
      hasText: "That account is already linked to another Quota account.",
    }),
  ).toBeVisible();
  await expect(page).not.toHaveURL(/linked=taken/);
});

test("landing provider marks resolve to files", async ({ page }) => {
  await page.goto("/");
  const providers = page.locator(".catalog-grid .name-list").first();
  await expect(providers.locator("li")).toHaveCount(12);
  await expect(providers.locator("img.provider-mark")).toHaveCount(12);
  for (const img of await providers.locator("img.provider-mark").all()) {
    expect(await img.evaluate((node) => (node as HTMLImageElement).naturalWidth)).toBeGreaterThan(
      0,
    );
  }
});

test("sign-in with intent=link lists bindable channels when signed in", async ({ page }) => {
  await mockAccountIdentities(page, [
    { provider: "github", label: "octocat", linked_at: "2026-01-04T12:00:00Z" },
  ]);
  await page.goto("/sign-in?intent=link");
  await expect(page.getByRole("heading", { name: "Link a sign-in method" })).toBeVisible();
  await expect(
    page.getByText(/Linking adds a way to sign in to the account you're already using/),
  ).toBeVisible();
  await expect(page.getByRole("heading", { name: "Sign-in methods" })).toBeVisible();
  await expect(page.getByRole("link", { name: "Link", exact: true })).toHaveAttribute(
    "href",
    "/api/auth/apple/start?intent=link&return_to=%2Fmy%2Fsettings",
  );
  await expect(page.getByRole("link", { name: /Continue as/ })).toHaveCount(0);
});

test("activity grid is one tab stop and Enter opens the day tree", async ({ page }) => {
  await mockV6(page);
  await page.goto("/my/usage");
  await expect(page.getByRole("heading", { name: "Activity" })).toBeVisible();
  await expect(page.locator("button.usage-activity-cell[tabindex='0']")).toHaveCount(1);

  const rover = page.locator("button.usage-activity-cell[tabindex='0']");
  await rover.focus();
  // End lands on today, the last cell; the day before it always exists in a 365-day grid,
  // whereas the cell after Home does not on the first day of a row.
  await page.keyboard.press("End");
  const start = await page
    .locator("button.usage-activity-cell[tabindex='0']")
    .getAttribute("data-date");
  // Left, not right: Home lands on the week's first in-range day, and on a Sunday that day is
  // today, which is also the last day the range has — there is nothing to its right.
  await page.keyboard.press("ArrowLeft");
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
    await expect(
      page.getByRole("heading", {
        name: "See what's left across your coding-agent plans.",
      }),
    ).toBeVisible();
    await expect(page.getByRole("link", { name: "Download for macOS" })).toBeVisible();
    await expect(page.getByRole("link", { name: "Sign in" }).first()).toBeVisible();
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
    if (viewport.width === 390) {
      const width = await page
        .locator(".preview-web")
        .evaluate((element) => element.getBoundingClientRect().width);
      expect(width).toBeGreaterThanOrEqual(280);
    }
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

async function chooseAppearance(page: Page, name: "Light" | "Dark"): Promise<void> {
  const toggle = page.locator("#theme-toggle");
  const expected = name.toLowerCase();
  await toggle.scrollIntoViewIfNeeded();
  // The landing paints screenshot CSS before ThemeToggle hydrates; a native click
  // on the still-inert option does not write data-theme. Retry until it does.
  await expect(async () => {
    if (!(await page.locator(".appearance-options").isVisible())) {
      await toggle.click();
    }
    const option = page.getByRole("button", { name, exact: true });
    await expect(option).toBeVisible();
    await option.click();
    await expect(page.locator("html")).toHaveAttribute("data-theme", expected);
  }).toPass();
}

test("landing screenshots follow an explicit Dark theme on a light OS", async ({ page }) => {
  await page.emulateMedia({ colorScheme: "light" });
  await page.goto("/");
  await expect(page.locator(".preview-web .shot-light")).toBeVisible();
  await expect(page.locator(".preview-web .shot-dark")).toBeHidden();
  await chooseAppearance(page, "Dark");
  await expect(page.locator("html")).toHaveAttribute("data-theme", "dark");
  await expect(page.locator(".preview-web .shot-dark")).toBeVisible();
  await expect(page.locator(".preview-web .shot-light")).toBeHidden();
});

test("landing screenshots follow an explicit Light theme on a dark OS", async ({ page }) => {
  await page.emulateMedia({ colorScheme: "dark" });
  await page.goto("/");
  await expect(page.locator(".preview-web .shot-dark")).toBeVisible();
  await expect(page.locator(".preview-web .shot-light")).toBeHidden();
  await chooseAppearance(page, "Light");
  await expect(page.locator("html")).toHaveAttribute("data-theme", "light");
  await expect(page.locator(".preview-web .shot-light")).toBeVisible();
  await expect(page.locator(".preview-web .shot-dark")).toBeHidden();
});
