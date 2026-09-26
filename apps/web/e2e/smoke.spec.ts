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

test("Home does not prefetch activity", async ({ page }) => {
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

test("moving between account pages does not refetch summary or activity", async ({ page }) => {
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
  const accountMenu = page.locator("#header-account-menu");
  await expect(page.locator(".quota-card").filter({ hasText: "Codex" })).toBeVisible();

  await page.locator("a.today-strip").click();
  await expect(page.getByRole("group", { name: "Usage activity by day" })).toBeVisible();

  await accountNav.getByRole("link", { name: "Models" }).click();
  await expect(page.getByRole("heading", { name: "By agent and model" })).toBeVisible();

  await accountNav.getByRole("link", { name: "Quota" }).click();
  await expect(page.locator(".quota-card").filter({ hasText: "Codex" })).toBeVisible();

  await accountMenu.locator("summary").click();
  await accountMenu.getByRole("link", { name: "Devices" }).click();
  await expect(page.locator("#device-list")).toContainText("Studio");

  await accountMenu.locator("summary").click();
  await accountMenu.getByRole("link", { name: "Settings" }).click();
  await expect(page.getByRole("heading", { name: "Delete Account" })).toBeVisible();

  await accountNav.getByRole("link", { name: "Home" }).click();
  await expect(page.locator(".quota-card").filter({ hasText: "Codex" })).toBeVisible();
  await expect(page.locator(".loading-block")).toHaveCount(0);

  await page.locator("a.today-strip").click();
  await expect(page.getByRole("group", { name: "Usage activity by day" })).toBeVisible();

  expect(summaryRequests).toBe(1);
  expect(activityListRequests).toBe(1);
});

test("the account shell carries the quota band, the Account nav, and the account menu", async ({
  page,
}) => {
  await mockV6(page);
  await page.goto("/my");

  const accountNav = page.getByRole("banner").getByRole("navigation", { name: "Account" });
  await expect(accountNav.getByRole("link", { name: "Home" })).toHaveAttribute(
    "aria-current",
    "page",
  );
  await expect(page.getByText(/Latest quota updated .* · \d+ devices? reporting/)).toBeVisible();

  const band = page.getByRole("navigation", { name: "Remaining quota" });
  await expect(band.locator("[data-provider]")).toHaveCount(accountSummary.subscriptions.length);
  await expect(band.getByRole("link", { name: "Quota →" })).toHaveAttribute("href", "/my/quota");

  const accountMenu = page.locator("#header-account-menu");
  await accountMenu.locator("summary").click();
  for (const name of ["Devices", "Settings", "Public page"]) {
    await expect(accountMenu.getByRole("link", { name })).toBeVisible();
  }
  await expect(accountMenu.getByRole("button", { name: "Sign out" })).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(accountMenu.getByRole("link", { name: "Devices" })).toBeHidden();

  await accountNav.getByRole("link", { name: "Quota" }).click();
  await expect(accountNav.getByRole("link", { name: "Quota" })).toHaveAttribute(
    "aria-current",
    "page",
  );
  await expect(page.locator(".quota-card").filter({ hasText: "Codex" })).toContainText("Plus");

  await page.goto("/my/usage");
  const tokens = page.locator("#token-total");
  await expect(tokens).not.toHaveText("—");
  const thirtyDayTokens = await tokens.innerText();
  await page.getByRole("button", { name: "Today", exact: true }).click();
  await expect(tokens).not.toHaveText(thirtyDayTokens);
  await expect(page).toHaveURL(/[?&]period=day(?:&|$)/);

  await page.goto("/my/devices");
  await expect(page.getByRole("columnheader", { name: "Last contact" })).toBeVisible();
  const deviceNames = page.locator("#device-list tbody th");
  await expect(deviceNames.nth(0)).toHaveText("Studio");
  await expect(deviceNames.nth(1)).toHaveText("Kitchen");
});

test("a band item opens its subscription, which names no device id or key", async ({ page }) => {
  await mockV6(page);
  await page.goto("/my");
  const band = page.getByRole("navigation", { name: "Remaining quota" });
  await band.locator("a[data-provider]").first().click();

  await expect(page).toHaveURL(/\/my\/subscriptions\/[a-f0-9]{12}$/);
  await expect(page.getByRole("link", { name: "← Quota" })).toBeVisible();
  await expect(page.getByText("Reporting")).toBeVisible();
  await expect(page.locator("body")).not.toContainText("codex_account_1");
  await expect(page.locator("body")).not.toContainText("device_1");
});

test("Usage keeps the model tree beside Activity at 1440 and above it at 390", async ({ page }) => {
  await mockV6(page);
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/my/usage");
  await expect(page.locator("#token-total")).not.toHaveText("—");
  await expect(page.getByRole("group", { name: "Usage activity by day" })).toBeVisible();
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
  const providers = page.getByRole("list", { name: "Providers" });
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

/** Every page opens on the same column: the header, the page header, and the footer align. */
const shellPages = [
  "/",
  "/sign-in",
  "/download",
  "/my",
  "/my/quota",
  "/my/devices",
  "/my/settings",
] as const;

async function openSettled(page: Page, path: string): Promise<void> {
  await page.goto(path);
  if (path.startsWith("/my")) {
    await expect(page.getByRole("navigation", { name: "Account" })).toBeVisible();
    await expect(page.locator(".loading-block")).toHaveCount(0);
  }
}

test("every page's content starts on the same left edge at 1440", async ({ page }) => {
  await mockV6(page);
  await page.setViewportSize({ width: 1440, height: 900 });
  const edges: Record<string, number> = {};
  for (const path of shellPages) {
    await openSettled(page, path);
    // The landing opens on its hero rather than a page header; both are the column's first line.
    const first = path === "/" ? page.locator("#hero-title") : page.locator("main h1");
    edges[path] = Math.round((await first.boundingBox())?.x ?? -1);
  }
  const brand = Math.round((await page.locator(".brand").boundingBox())?.x ?? -2);
  expect(new Set(Object.values(edges))).toEqual(new Set([brand]));
  expect(brand).toBe((1440 - 1080) / 2);
});

for (const path of [...shellPages, "/my/models", "/my/recap", "/my/usage", "/u/octocat"]) {
  test(`${path} fits 390 px and axe finds nothing serious`, async ({ page }) => {
    await mockV6(page);
    await page.setViewportSize({ width: 390, height: 844 });
    await openSettled(page, path);
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
    const results = await new AxeBuilder({ page }).analyze();
    expect(seriousOrCritical(results.violations)).toEqual([]);
  });
}

async function chooseAppearance(page: Page, name: "Light" | "Dark"): Promise<void> {
  const appearance = page.getByRole("group", { name: "Appearance" });
  const expected = name.toLowerCase();
  await appearance.scrollIntoViewIfNeeded();
  // The landing paints before ThemeToggle hydrates; a click on the still-inert button does not
  // write data-theme. Retry until it does.
  await expect(async () => {
    await appearance.getByRole("button", { name, exact: true }).click();
    await expect(page.locator("html")).toHaveAttribute("data-theme", expected);
  }).toPass();
}

test("landing screenshots follow an explicit Dark theme on a light OS", async ({ page }) => {
  await page.emulateMedia({ colorScheme: "light" });
  await page.goto("/");
  await expect(page.locator(".preview-web .shot-light")).toBeVisible();
  await expect(page.locator(".preview-web .shot-dark")).toBeHidden();
  await chooseAppearance(page, "Dark");
  await expect(page.locator(".preview-web .shot-dark")).toBeVisible();
  await expect(page.locator(".preview-web .shot-light")).toBeHidden();
});

test("landing screenshots follow an explicit Light theme on a dark OS", async ({ page }) => {
  await page.emulateMedia({ colorScheme: "dark" });
  await page.goto("/");
  await expect(page.locator(".preview-web .shot-dark")).toBeVisible();
  await expect(page.locator(".preview-web .shot-light")).toBeHidden();
  await chooseAppearance(page, "Light");
  await expect(page.locator(".preview-web .shot-light")).toBeVisible();
  await expect(page.locator(".preview-web .shot-dark")).toBeHidden();
});
