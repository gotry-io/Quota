import AxeBuilder from "@axe-core/playwright";
import { expect, type Page, test } from "@playwright/test";
import { AccountResponseSchema } from "@gotry-io/quota-protocol";
import {
  accountActivity,
  accountActivityDay,
  accountReadFromSummary,
  accountSummary,
  screenshotAccountSummary,
} from "./account-fixture.ts";

async function mockProviderStatus(
  page: Page,
  providers: Array<{
    id: string;
    indicator: string;
    description: string;
    checked_at: string;
  }> = [
    {
      id: "codex",
      indicator: "minor",
      description: "Partial System Outage",
      checked_at: "2026-09-06T00:00:00Z",
    },
  ],
): Promise<void> {
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
        body: JSON.stringify({ providers }),
      });
    },
  );
}

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

test("Overview does not prefetch activity", async ({ page }) => {
  let activityListRequests = 0;
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
      if (asked.searchParams.get("detail") !== "agents") activityListRequests += 1;
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
});

test("switching account tabs does not refetch summary or activity", async ({ page }) => {
  let summaryRequests = 0;
  let activityListRequests = 0;
  await mockAccountRead(page);
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
  await expect(page.getByText(/Latest quota updated .* · \d+ devices? reporting/)).toBeVisible();
  await expect(
    page.getByText("Sync is off. Your Macs stop uploading until you subscribe."),
  ).toHaveCount(0);
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

test("Settings groups Appearance, Sync, Sign-in methods, Account, and Legal", async ({ page }) => {
  await mockV6(page);
  await page.goto("/my/settings");
  await expect(page.getByRole("heading", { name: "Appearance" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Sync" })).toBeVisible();
  await expect(page.getByText(/Active · renews /)).toBeVisible();
  await expect(page.getByRole("link", { name: "Manage subscription" })).toHaveAttribute(
    "target",
    "_blank",
  );
  await expect(page.getByRole("link", { name: "Manage subscription" })).toHaveAttribute(
    "rel",
    "noopener",
  );
  await expect(page.getByRole("heading", { name: "Notifications" })).toHaveCount(0);
  await expect(page.getByRole("heading", { name: "Sign-in methods" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Account", exact: true })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Legal" })).toBeVisible();
  await expect(
    page.locator(".settings-links").getByRole("link", { name: "Privacy" }),
  ).toHaveAttribute("href", "/privacy");
  await expect(
    page.locator(".settings-links").getByRole("link", { name: "Terms" }),
  ).toHaveAttribute("href", "/terms");
  await expect(
    page.locator(".settings-group").getByRole("button", { name: "Sign out" }),
  ).toHaveCount(0);
  await expect(page.getByRole("heading", { name: "Delete Account" })).toBeVisible();
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

test("Settings Sign-in methods: last channel cannot be unlinked", async ({ page }) => {
  await mockAccountIdentities(page, [
    { provider: "github", label: "octocat", linked_at: "2026-01-04T12:00:00Z" },
  ]);
  await page.goto("/my/settings");
  const group = page.locator(".settings-group").filter({ hasText: "Sign-in methods" });
  await expect(group.getByText("Apple", { exact: true })).toBeVisible();
  await expect(group.getByText("GitHub", { exact: true })).toBeVisible();
  await expect(group.getByText("Email", { exact: true })).toBeVisible();
  await expect(group.getByText("octocat")).toBeVisible();
  await expect(group.getByRole("button", { name: "Unlink" })).toBeDisabled();
  await expect(group.getByText("Keep at least one way to sign in")).toBeVisible();
  await expect(group.getByRole("link", { name: "Link", exact: true })).toHaveAttribute(
    "href",
    "/api/auth/apple/start?intent=link&return_to=%2Fmy%2Fsettings",
  );
  await expect(group.getByRole("button", { name: "Link", exact: true })).toBeVisible();
});

test("Settings Sign-in methods: mixed bound channels can be unlinked", async ({ page }) => {
  await mockAccountIdentities(page, [
    { provider: "github", label: "octocat", linked_at: "2026-01-04T12:00:00Z" },
    {
      provider: "apple",
      label: "kyle@privaterelay.appleid.com",
      linked_at: "2026-02-01T12:00:00Z",
    },
  ]);
  await page.goto("/my/settings");
  const group = page.locator(".settings-group").filter({ hasText: "Sign-in methods" });
  await expect(group.getByText("kyle@privaterelay.appleid.com")).toBeVisible();
  await expect(group.getByText("octocat")).toBeVisible();
  const unlinks = group.getByRole("button", { name: "Unlink" });
  await expect(unlinks).toHaveCount(2);
  await expect(unlinks.first()).toBeEnabled();
  await expect(group.getByText("Keep at least one way to sign in")).toHaveCount(0);
  await expect(group.getByRole("button", { name: "Link", exact: true })).toBeVisible();
  await expect(group.getByRole("link", { name: "Link", exact: true })).toHaveCount(0);
});

test("Settings Sign-in methods: Email Link sends a link and shows Check your email", async ({
  page,
}) => {
  await mockAccountIdentities(page, [
    { provider: "github", label: "octocat", linked_at: "2026-01-04T12:00:00Z" },
  ]);
  await page.route("**/api/auth/email/start", async (route) => {
    expect(route.request().method()).toBe("POST");
    expect(JSON.parse(route.request().postData() ?? "{}")).toEqual({
      email: "person@example.test",
      return_to: "/my/settings",
      intent: "link",
    });
    await route.fulfill({
      status: 202,
      contentType: "application/json",
      body: JSON.stringify({ status: "accepted" }),
    });
  });
  await page.goto("/my/settings");
  const group = page.locator(".settings-group").filter({ hasText: "Sign-in methods" });
  await group.getByRole("button", { name: "Link", exact: true }).click();
  await group.getByLabel("Email").fill("person@example.test");
  await group.getByRole("button", { name: "Send sign-in link" }).click();
  await expect(group.getByRole("status")).toContainText("Check your email");
});

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

test("screenshot account fixture matches AccountResponse", () => {
  expect(
    AccountResponseSchema.safeParse(accountReadFromSummary(screenshotAccountSummary())).success,
  ).toBe(true);
  expect(AccountResponseSchema.safeParse(accountReadFromSummary()).success).toBe(true);
});

test("landing provider marks resolve to files", async ({ page }) => {
  await page.goto("/");
  const providers = page.locator(".catalog-grid .name-list").first();
  await expect(providers.locator("li")).toHaveCount(10);
  await expect(providers.locator("img.provider-mark")).toHaveCount(10);
  for (const img of await providers.locator("img.provider-mark").all()) {
    expect(await img.evaluate((node) => (node as HTMLImageElement).naturalWidth)).toBeGreaterThan(
      0,
    );
  }
});

test("Overview draws a status dot for minor and above", async ({ page }) => {
  await mockV6(page);
  await mockProviderStatus(page);
  await page.goto("/my");
  const codex = page.locator(".quota-card").filter({ hasText: "Codex" });
  await expect(codex).toBeVisible();
  const dot = codex.locator(".provider-status-dot");
  await expect(dot).toBeVisible();
  await expect(dot).toHaveAttribute("title", "Partial System Outage");
});

test("Usage states how many rows the catalog priced", async ({ page }) => {
  await mockV6(page);
  await page.goto("/my/usage");
  await expect(page.locator("#cost-priced")).toHaveText(/Priced \d+ of \d+ rows/);
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

test.describe("signed-out sign-in", () => {
  test.use({ extraHTTPHeaders: { "x-quota-dev-signed-out": "1" } });

  test("sign-in with intent=link signs in the usual way then Settings", async ({ page }) => {
    await page.goto("/sign-in?intent=link");
    await expect(page.getByRole("heading", { name: "Link a sign-in method" })).toBeVisible();
    await expect(
      page.getByText(/Linking adds a way to sign in to the account you're already using/),
    ).toBeVisible();
    const apple = page.getByRole("link", { name: "Continue with Apple" });
    const github = page.getByRole("link", { name: "Continue with GitHub" });
    await expect(apple).toBeVisible();
    await expect(github).toBeVisible();
    await expect(apple).toHaveAttribute("href", "/api/auth/apple/start?return_to=%2Fmy%2Fsettings");
    await expect(github).toHaveAttribute(
      "href",
      "/api/auth/github/start?return_to=%2Fmy%2Fsettings",
    );
  });
});

test("sign-in asks to continue as the signed-in Account", async ({ page }) => {
  await page.goto("/sign-in");
  await expect(page.getByRole("heading", { name: "You're signed in" })).toBeVisible();
  await expect(page.getByRole("link", { name: "Continue as octocat" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Use a different account" })).toBeVisible();
});

test("sign-in for Delete Account asks to sign in again", async ({ page }) => {
  await page.goto(`/sign-in?return_to=${encodeURIComponent("/my/settings?delete=account")}`);
  await expect(
    page.getByRole("heading", { name: "Sign in again to delete your account" }),
  ).toBeVisible();
  await expect(page.getByRole("link", { name: "Continue as octocat" })).toHaveCount(0);
  const apple = page.getByRole("link", { name: "Continue with Apple" });
  const github = page.getByRole("link", { name: "Continue with GitHub" });
  await expect(apple).toBeVisible();
  await expect(github).toBeVisible();
  expect(await apple.evaluate((node) => node.getBoundingClientRect().top)).toBeLessThan(
    await github.evaluate((node) => node.getBoundingClientRect().top),
  );
});

function unsubscribedSummary(): unknown {
  const summary = structuredClone(accountSummary) as {
    entitlement: {
      status: string;
      expires_at: string | null;
      will_renew: boolean;
      stale: boolean;
    };
  };
  summary.entitlement = {
    ...summary.entitlement,
    status: "none",
    expires_at: null,
    will_renew: false,
    stale: false,
  };
  return summary;
}

test("Overview warns when sync is off and Settings offers Subscribe", async ({ page }) => {
  await mockV6(page, unsubscribedSummary());
  await page.goto("/my");
  const notice = page.getByRole("status").filter({
    hasText: "Sync is off. Your Macs stop uploading until you subscribe.",
  });
  await expect(notice).toBeVisible();
  await expect(notice.getByRole("link", { name: "Settings" })).toHaveAttribute(
    "href",
    "/my/settings",
  );

  await page.goto("/my/settings");
  await expect(page.getByText("Not subscribed")).toBeVisible();
  await expect(page.getByRole("link", { name: "Subscribe" })).toHaveAttribute("target", "_blank");

  await page.goto("/my/devices");
  await expect(page.getByText("Paused (no subscription)").first()).toBeVisible();
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
  await toggle.scrollIntoViewIfNeeded();
  await toggle.click();
  const option = page.getByRole("button", { name, exact: true });
  await expect(option).toBeVisible();
  await option.click();
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

test("a recent device heartbeat does not make stale quota look fresh", async ({ page }) => {
  const summary = structuredClone(accountSummary) as typeof accountSummary & {
    devices: Array<{ last_seen_at: string | null }>;
    subscriptions: Array<{ snapshot: { observed_at: string } }>;
  };
  const firstDevice = summary.devices[0];
  const firstSubscription = summary.subscriptions[0];
  if (!firstDevice || !firstSubscription) throw new Error("account fixture is missing rows");
  firstDevice.last_seen_at = new Date().toISOString();
  firstSubscription.snapshot.observed_at = "2020-01-01T00:00:00Z";
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
    await route.fulfill({ status: 404, contentType: "application/json", body: "{}" });
  });
  await page.goto("/my");
  const status = page.locator(".dashboard-status");
  await expect(status).toContainText("Latest quota updated");
  await expect(status).not.toContainText("just now");
});

test("unknown Device platforms use a generic icon", async ({ page }) => {
  const summary = structuredClone(accountSummary) as typeof accountSummary & {
    devices: Array<{
      id: string;
      display_name: string;
      platform: string;
      last_seen_at: string | null;
      last_observed_at: string | null;
    }>;
  };
  summary.devices.push({
    id: "device_linux",
    display_name: "Lab Box",
    platform: "linux",
    last_seen_at: "2026-08-10T09:31:00Z",
    last_observed_at: "2026-08-10T09:00:00Z",
  });
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
    await route.fulfill({ status: 404, contentType: "application/json", body: "{}" });
  });
  await page.goto("/my/devices");
  await expect(page.getByRole("img", { name: "Unknown" }).first()).toBeVisible();
  await expect(page.getByRole("rowheader", { name: "Lab Box" })).toBeVisible();
});

test("Devices below 620 px are two-column cards with Last contact", async ({ page }) => {
  await mockV6(page);
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/my/devices");
  await expect(page.locator(".device-card-list")).toBeVisible();
  await expect(page.locator(".device-card dt", { hasText: "Last contact" }).first()).toBeVisible();
  await expect(page.locator(".device-table-wrap")).toBeHidden();
});

test("Support names the Notifications anchor", async ({ page }) => {
  await page.goto("/support#notifications");
  await expect(page.locator("#notifications")).toBeVisible();
  await expect(
    page.getByText(
      "Remaining-quota alerts and reset reminders are configured and evaluated in QuotaBar on your Mac. The website does not send notifications.",
    ),
  ).toBeVisible();
});
