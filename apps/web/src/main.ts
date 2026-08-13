import {
  type AccountDevice,
  type AccountQuotaObservation,
  type AccountSummary,
  AccountResponseSchema,
  AccountSummarySchema,
  DeviceAuthorizationDecisionRequestSchema,
  PROTOCOL_VERSION,
  type UsageBreakdown,
  type UsageCostOutcome,
} from "@gotry-io/quota-protocol";
import "./styles.css";
import { PublicProfileSchema } from "@gotry-io/quota-protocol";
import {
  accountEntryAction,
  DASHBOARD_PATH,
  legacyDashboardRedirect,
  planDisplayName,
  publicProfileUsername,
} from "./routes.ts";

const WEB_LOCALE = "en-US";
const THEME_STORAGE_KEY = "quota-theme";

bindAppearanceToggle();

const year = document.querySelector<HTMLElement>("#copyright-year");
if (year) year.textContent = String(new Date().getFullYear());
for (const button of document.querySelectorAll<HTMLButtonElement>("[data-web-login]")) {
  button.addEventListener("click", () => {
    void openAccountOrLogin();
  });
}
document.querySelector<HTMLButtonElement>("[data-copy-brew]")?.addEventListener("click", () => {
  const command = document.querySelector("#brew-install")?.textContent?.trim();
  if (command) void navigator.clipboard.writeText(command);
});
document.querySelector<HTMLFormElement>("#logout-form")?.addEventListener("submit", (event) => {
  event.preventDefault();
  void logout();
});
document.querySelector<HTMLButtonElement>("#delete-account")?.addEventListener("click", () => {
  void deleteAccount();
});
const accountMenu = document.querySelector<HTMLDetailsElement>(".account-menu");
document.addEventListener("pointerdown", (event) => {
  if (accountMenu?.open && event.target instanceof Node && !accountMenu.contains(event.target)) {
    accountMenu.open = false;
  }
});

const path = window.location.pathname;
const legacyPath = legacyDashboardRedirect(path);
const publicUsername = publicProfileUsername(path);
if (legacyPath) {
  window.location.replace(legacyPath);
} else if (path === DASHBOARD_PATH) {
  requiredElement("landing-view").hidden = true;
  requiredElement("route-loading").hidden = false;
  void showDashboard();
} else if (publicUsername) {
  void showPublicProfile(publicUsername);
  void hydrateHeader();
} else if (path === "/activate") {
  showActivation();
  void hydrateHeader();
} else {
  void hydrateHeader();
}

async function showDashboard(): Promise<void> {
  try {
    const request = {
      credentials: "same-origin",
      redirect: "error",
      headers: { Accept: "application/json" },
    } satisfies RequestInit;
    const response = await fetch(
      "/api/v2/account/summary?cost_mode=calculate&usage_agents=all&model_catalog=1",
      request,
    );
    if (response.status === 401) {
      window.location.replace("/");
      return;
    }
    if (!response.ok) throw new Error("account_unavailable");
    const parsed = AccountSummarySchema.safeParse(await response.json());
    if (!parsed.success) throw new Error("invalid_account_summary");
    setView("dashboard-view");
    showSignedInHeader(parsed.data.account.display_label);
    renderDashboard(parsed.data);
  } catch {
    setView("dashboard-view");
    showAccountError("Quota could not load this account. Refresh to try again.");
    showUsageActivityMessage("Usage activity is unavailable.");
  }
}

function renderDashboard(summary: AccountSummary): void {
  text("input-total", formatCount(summary.usage.totals.input_tokens));
  text("output-total", formatCount(summary.usage.totals.output_tokens));
  text("cost-total", formatCost(summary.usage.cost));
  text("cost-coverage", costCoverage(summary.usage.cost));
  text("device-count", String(summary.devices.length));

  const devicesByID = new Map(summary.devices.map((device) => [device.device_id, device]));
  const quotas = requiredElement("quota-list");
  quotas.replaceChildren(
    ...summary.quota.map((observation) =>
      renderQuotaObservation(observation, devicesByID.get(observation.device_id)?.display_name),
    ),
  );
  if (summary.quota.length === 0) {
    quotas.append(emptyState("No quota snapshots yet. Sign in from QuotaBar to add this Mac."));
  }

  const devices = requiredElement("device-list");
  devices.replaceChildren(...summary.devices.map(renderDevice));
  if (summary.devices.length === 0) {
    devices.append(emptyState("No devices yet. Sign in from QuotaBar to add this Mac."));
  }

  const breakdowns = summary.usage.breakdowns.filter((item) => item.dimension === "agent");
  renderBreakdownTable("usage-breakdown", breakdowns, "No Usage has been synced for this range.");
  const modelBreakdowns = summary.usage.breakdowns.filter((item) => item.dimension === "model");
  renderBreakdownTable(
    "model-breakdown",
    modelBreakdowns,
    "No model Usage has been synced for this range.",
  );
  renderUsageActivity(
    summary.usage.breakdowns.filter((item) => item.dimension === "usage_date"),
    summary.usage.range,
  );
}

function renderQuotaObservation(
  observation: AccountQuotaObservation,
  deviceName: string | undefined,
): HTMLElement {
  const snapshot = observation.snapshot;
  const card = document.createElement("article");
  card.className = "quota-card";

  const heading = document.createElement("div");
  heading.className = "quota-card-heading";
  const identity = document.createElement("div");
  identity.className = "quota-card-identity";
  const provider = document.createElement("p");
  provider.className = "quota-card-provider";
  provider.textContent = titleCase(snapshot.provider);
  const account = document.createElement("p");
  account.className = "quota-card-account";
  const plan = planDisplayName(snapshot.account.plan);
  account.textContent = [snapshot.account.label, plan].filter(Boolean).join(" · ") || "Account";
  identity.append(provider, account);
  const status = document.createElement("span");
  status.className = `status-pill status-${snapshot.status}`;
  status.textContent = snapshot.status.replaceAll("_", " ");
  heading.append(identity, status);

  const windows = document.createElement("div");
  windows.className = "quota-window-list";
  windows.append(...snapshot.windows.map(renderQuotaWindow));
  if (snapshot.windows.length === 0) {
    windows.append(emptyState("No quota windows reported."));
  }

  const meta = document.createElement("p");
  meta.className = "quota-card-meta";
  meta.textContent = `${deviceName ?? "Device"} · ${formatDate(snapshot.observed_at)}`;
  card.append(heading, windows, meta);
  return card;
}

function renderQuotaWindow(
  window: AccountQuotaObservation["snapshot"]["windows"][number],
): HTMLElement {
  const item = document.createElement("div");
  item.className = "quota-window-card";
  const heading = document.createElement("div");
  heading.className = "quota-window-heading";
  const title = document.createElement("span");
  const balanceOnly = window.remaining_value !== undefined && window.limit_value === undefined;
  title.textContent = balanceOnly ? "Balance" : window.title;
  const remaining = document.createElement("strong");
  remaining.textContent = formatQuotaRemaining(window);
  heading.append(title, remaining);

  item.append(heading);
  if (!balanceOnly) {
    const track = document.createElement("div");
    track.className = "quota-track";
    const fill = document.createElement("span");
    fill.style.width = `${Math.max(0, Math.min(100, 100 - window.used_percent))}%`;
    fill.setAttribute("aria-hidden", "true");
    track.append(fill);
    item.append(track);
  }

  if (window.resets_at || !balanceOnly) {
    const meta = document.createElement("p");
    meta.className = "quota-window-meta";
    meta.textContent = window.resets_at
      ? `Resets ${formatDate(window.resets_at)}`
      : "No reset time reported";
    item.append(meta);
  }
  return item;
}

function formatQuotaRemaining(
  window: AccountQuotaObservation["snapshot"]["windows"][number],
): string {
  const percent = formatPercent(100 - window.used_percent);
  const absolute = formatAbsoluteRemaining(window);
  const balanceOnly = window.remaining_value !== undefined && window.limit_value === undefined;
  if (absolute === undefined) {
    return percent;
  }
  if (balanceOnly) {
    return absolute;
  }
  return `${percent} · ${absolute}`;
}

function formatAbsoluteRemaining(
  window: AccountQuotaObservation["snapshot"]["windows"][number],
): string | undefined {
  if (window.remaining_value === undefined) {
    return undefined;
  }
  if (window.value_unit === "usd") {
    return new Intl.NumberFormat(WEB_LOCALE, {
      style: "currency",
      currency: "USD",
      maximumFractionDigits: 2,
    }).format(window.remaining_value);
  }
  return `${formatCount(window.remaining_value)}${window.value_unit === "credits" ? " credits" : ""}`;
}

function formatPercent(value: number): string {
  return `${new Intl.NumberFormat(WEB_LOCALE, { maximumFractionDigits: 0 }).format(value)}%`;
}

function renderBreakdownTable(
  id: string,
  breakdowns: UsageBreakdown[],
  emptyMessage: string,
): void {
  const table = requiredElement(id);
  table.replaceChildren(...breakdowns.map(renderBreakdown));
  if (breakdowns.length === 0) {
    const row = document.createElement("tr");
    const cell = document.createElement("td");
    cell.colSpan = 4;
    cell.textContent = emptyMessage;
    row.append(cell);
    table.append(row);
  }
}

function renderDevice(device: AccountDevice): HTMLElement {
  const card = document.createElement("article");
  card.className = "device-card";
  const heading = document.createElement("div");
  heading.className = "device-card-heading";
  const title = document.createElement("h3");
  title.textContent = device.display_name;
  const status = document.createElement("span");
  status.className = `status-pill status-${device.status}`;
  status.textContent = device.status.replace("_", " ");
  heading.append(title, status);
  const meta = document.createElement("p");
  meta.textContent = `${device.platform} · ${device.last_seen_at ? `seen ${formatDate(device.last_seen_at)}` : "not synced"}`;
  const remove = document.createElement("button");
  remove.className = "text-button danger-button";
  remove.type = "button";
  remove.textContent = "Delete device and data";
  remove.addEventListener("click", () => void deleteDevice(device, remove));
  card.append(heading, meta, remove);
  return card;
}

async function deleteDevice(device: AccountDevice, button: HTMLButtonElement): Promise<void> {
  if (!window.confirm(`Delete ${device.display_name} and all of its Quota and Usage data?`)) return;
  button.disabled = true;
  try {
    const response = await fetch(
      `/api/v2/account/devices/${encodeURIComponent(device.device_id)}`,
      {
        method: "DELETE",
        credentials: "same-origin",
        redirect: "error",
        headers: { Accept: "application/json" },
      },
    );
    if (response.status === 403) {
      void beginWebLogin(DASHBOARD_PATH);
      return;
    }
    if (!response.ok) throw new Error("delete_failed");
    await showDashboard();
  } catch {
    button.disabled = false;
    showAccountError("Quota could not delete this device. Recent authentication may be required.");
  }
}

async function deleteAccount(): Promise<void> {
  if (!window.confirm("Delete this Quota Account and all of its Device, quota, and Usage data?")) {
    return;
  }
  const button = requiredElement<HTMLButtonElement>("delete-account");
  button.disabled = true;
  try {
    const response = await fetch("/api/auth/v2/delete-user", {
      method: "POST",
      credentials: "same-origin",
      redirect: "error",
      headers: { Accept: "application/json", "Content-Type": "application/json" },
      body: "{}",
    });
    if ([400, 401, 403].includes(response.status)) {
      void beginWebLogin(DASHBOARD_PATH);
      return;
    }
    if (!response.ok) throw new Error("delete_failed");
    window.location.assign("/");
  } catch {
    button.disabled = false;
    showAccountError("Quota could not delete this Account. Recent authentication may be required.");
  }
}

function renderBreakdown(item: UsageBreakdown): HTMLTableRowElement {
  const row = document.createElement("tr");
  const values = [
    item.dimension === "model"
      ? item.key
      : item.dimension === "agent"
        ? agentDisplayName(item.key)
        : titleCase(item.key),
    formatCount(item.totals.input_tokens),
    formatCount(item.totals.output_tokens),
    formatCost(item.cost),
  ];
  for (const value of values) {
    const cell = document.createElement("td");
    cell.textContent = value;
    row.append(cell);
  }
  return row;
}

function agentDisplayName(agent: string): string {
  switch (agent) {
    case "claude_code":
      return "Claude Code";
    case "opencode":
      return "OpenCode";
    case "pi":
      return "Pi";
    case "cursor":
      return "Cursor";
    default:
      return titleCase(agent);
  }
}

function renderUsageActivity(
  breakdowns: UsageBreakdown[],
  range: AccountSummary["usage"]["range"],
): void {
  requiredElement("usage-activity-status").textContent = `${range.from} – ${range.to}`;
  const totals = new Map<string, { requests: number; tokens: number }>();
  for (const breakdown of breakdowns) {
    if (breakdown.key < range.from || breakdown.key > range.to) continue;
    const current = totals.get(breakdown.key) ?? { requests: 0, tokens: 0 };
    current.requests = safeAdd(current.requests, breakdown.totals.requests);
    // Cache and reasoning counters are input/output subsets in the protocol, not extra tokens.
    current.tokens = safeAdd(
      current.tokens,
      breakdown.totals.input_tokens,
      breakdown.totals.output_tokens,
    );
    totals.set(breakdown.key, current);
  }

  const first = new Date(`${range.from}T00:00:00Z`);
  first.setUTCDate(first.getUTCDate() - first.getUTCDay());
  const last = new Date(`${range.to}T00:00:00Z`);
  last.setUTCDate(last.getUTCDate() + (6 - last.getUTCDay()));
  const maxTokens = Math.max(...[...totals.values()].map((value) => value.tokens), 0);
  const today = new Date().toISOString().slice(0, 10);
  const list = document.createElement("ul");
  list.className = "usage-activity-grid";
  list.setAttribute("aria-label", "Usage activity by day");
  for (const cursor = new Date(first); cursor <= last; cursor.setUTCDate(cursor.getUTCDate() + 1)) {
    const date = cursor.toISOString().slice(0, 10);
    const value = totals.get(date);
    const cell = document.createElement("li");
    const level = activityLevel(value?.tokens ?? 0, maxTokens);
    cell.className = `usage-activity-cell activity-level-${level}`;
    if (date === today) cell.classList.add("activity-today");
    if (date < range.from || date > range.to) {
      cell.classList.add("activity-outside");
      cell.setAttribute("aria-hidden", "true");
    } else {
      const requests = value?.requests ?? 0;
      const tokens = value?.tokens ?? 0;
      const label = `${formatShortDate(date)}: ${formatCount(requests)} messages, ${formatCount(tokens)} tokens`;
      cell.setAttribute("aria-label", label);
      cell.title = label;
    }
    list.append(cell);
  }
  const target = requiredElement("usage-activity-grid");
  target.replaceChildren(list);
}

function showUsageActivityMessage(message: string): void {
  const target = requiredElement("usage-activity-grid");
  target.textContent = message;
}

function activityLevel(value: number, maximum: number): number {
  if (value <= 0 || maximum <= 0) return 0;
  return Math.min(4, Math.ceil((value / maximum) * 4));
}

function safeAdd(...values: number[]): number {
  return Math.min(
    Number.MAX_SAFE_INTEGER,
    values.reduce((total, value) => total + value, 0),
  );
}

function formatShortDate(value: string): string {
  return new Intl.DateTimeFormat(WEB_LOCALE, {
    month: "short",
    day: "numeric",
    timeZone: "UTC",
  }).format(new Date(`${value}T00:00:00Z`));
}

function showActivation(): void {
  setView("activate-view");
  const input = requiredElement<HTMLInputElement>("user-code");
  const code = new URLSearchParams(window.location.search).get("user_code");
  if (code) input.value = code;
  const form = requiredElement<HTMLFormElement>("activate-form");
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    void decideActivation("approve");
  });
  requiredElement<HTMLButtonElement>("deny-activation").addEventListener("click", () => {
    void decideActivation("deny");
  });
}

async function decideActivation(decision: "approve" | "deny"): Promise<void> {
  const input = requiredElement<HTMLInputElement>("user-code");
  const request = DeviceAuthorizationDecisionRequestSchema.safeParse({
    protocol_version: PROTOCOL_VERSION,
    user_code: input.value.trim(),
    decision,
  });
  if (!request.success) {
    showActivationStatus("Enter the exact code shown by your Quota client.");
    return;
  }
  const returnTo = `/activate?user_code=${encodeURIComponent(request.data.user_code)}`;
  try {
    const response = await fetch("/oauth/v2/device/authorize", {
      method: "POST",
      credentials: "same-origin",
      redirect: "error",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
      },
      body: JSON.stringify(request.data),
    });
    if (response.status === 401 || response.status === 403) {
      void beginWebLogin(returnTo);
      return;
    }
    if (!response.ok) throw new Error("decision_failed");
    input.disabled = true;
    showActivationStatus(
      decision === "approve"
        ? "Installation authorized. Return to your Quota client."
        : "Authorization denied. You can close this page.",
    );
  } catch {
    showActivationStatus(
      "Quota could not update this authorization. Check the code and try again.",
    );
  }
}

async function logout(): Promise<void> {
  try {
    const response = await fetch("/api/auth/v2/sign-out", {
      method: "POST",
      credentials: "same-origin",
      redirect: "error",
      headers: { Accept: "application/json" },
    });
    if (!response.ok) throw new Error("logout_failed");
    window.location.assign("/");
  } catch {
    showAccountError("Quota could not sign out this browser session. Refresh and try again.");
  }
}

function setView(id: "dashboard-view" | "activate-view" | "public-view"): void {
  requiredElement("landing-view").hidden = true;
  requiredElement("dashboard-view").hidden = id !== "dashboard-view";
  requiredElement("activate-view").hidden = id !== "activate-view";
  requiredElement("public-view").hidden = id !== "public-view";
  requiredElement("route-loading").hidden = true;
}

function preferredAppearance(): "light" | "dark" {
  const stored = localStorage.getItem(THEME_STORAGE_KEY);
  if (stored === "light" || stored === "dark") return stored;
  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

function applyAppearance(theme: "light" | "dark"): void {
  document.documentElement.dataset.theme = theme;
  document.documentElement.style.colorScheme = theme;
  document
    .querySelector<HTMLMetaElement>('meta[name="theme-color"]')
    ?.setAttribute("content", theme === "dark" ? "#111111" : "#f2f8f5");
  const toggle = document.querySelector<HTMLButtonElement>("#theme-toggle");
  if (toggle) {
    toggle.setAttribute(
      "aria-label",
      theme === "dark" ? "Use light appearance" : "Use dark appearance",
    );
  }
}

function bindAppearanceToggle(): void {
  applyAppearance(preferredAppearance());
  window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
    const stored = localStorage.getItem(THEME_STORAGE_KEY);
    if (stored !== "light" && stored !== "dark") applyAppearance(preferredAppearance());
  });
  document.querySelector("#theme-toggle")?.addEventListener("click", () => {
    const next = preferredAppearance() === "dark" ? "light" : "dark";
    localStorage.setItem(THEME_STORAGE_KEY, next);
    applyAppearance(next);
  });
}

async function showPublicProfile(username: string): Promise<void> {
  setView("public-view");
  const error = requiredElement("public-error");
  const body = requiredElement("public-body");
  error.hidden = true;
  body.hidden = true;
  const response = await fetch(`/api/v2/public/profiles/${encodeURIComponent(username)}`, {
    redirect: "error",
    headers: { Accept: "application/json" },
  });
  if (response.status === 404) {
    error.hidden = false;
    error.textContent = "This profile is private or does not exist.";
    return;
  }
  const parsed = PublicProfileSchema.safeParse(await response.json());
  if (!parsed.success) {
    error.hidden = false;
    error.textContent = "Quota could not load this public profile.";
    return;
  }
  body.hidden = false;
  text("public-input-total", formatCount(parsed.data.usage.input_tokens));
  text("public-output-total", formatCount(parsed.data.usage.output_tokens));
  text(
    "public-cost-total",
    parsed.data.usage.cost_status === "unavailable" || parsed.data.usage.amount_microusd === null
      ? "— unpriced"
      : new Intl.NumberFormat(WEB_LOCALE, {
          style: "currency",
          currency: "USD",
          maximumFractionDigits: 2,
        }).format(Number(parsed.data.usage.amount_microusd) / 1_000_000),
  );
  const quotas = requiredElement("public-quota-list");
  quotas.replaceChildren(
    ...parsed.data.quota.map((provider) => {
      const card = document.createElement("article");
      card.className = "quota-card";
      const heading = document.createElement("div");
      heading.className = "quota-card-heading";
      const identity = document.createElement("div");
      identity.className = "quota-card-identity";
      const name = document.createElement("p");
      name.className = "quota-card-provider";
      name.textContent = titleCase(provider.provider);
      const plan = document.createElement("p");
      plan.className = "quota-card-account";
      plan.textContent = provider.plan ?? "Account";
      identity.append(name, plan);
      heading.append(identity);
      const list = document.createElement("div");
      list.className = "quota-window-list";
      for (const window of provider.windows) {
        list.append(
          renderQuotaWindow({
            ...window,
            id: window.title,
            used_percent: window.used_percent,
          }),
        );
      }
      card.append(heading, list);
      return card;
    }),
  );
  const models = requiredElement("public-model-breakdown");
  models.replaceChildren();
  for (const model of parsed.data.usage.models) {
    const row = document.createElement("tr");
    const name = document.createElement("th");
    name.scope = "row";
    name.textContent = model.name;
    const tokens = document.createElement("td");
    tokens.textContent = formatCount(model.tokens);
    row.append(name, tokens);
    models.append(row);
  }
}

function showAccountError(message: string): void {
  const notice = requiredElement("account-error");
  notice.textContent = message;
  notice.hidden = false;
}

function showActivationStatus(message: string): void {
  const status = requiredElement("activate-status");
  status.textContent = message;
  status.hidden = false;
}

function emptyState(message: string): HTMLElement {
  const element = document.createElement("p");
  element.className = "empty-state";
  element.textContent = message;
  return element;
}

function formatCount(value: number): string {
  return new Intl.NumberFormat(WEB_LOCALE, {
    notation: "compact",
    maximumFractionDigits: 1,
  }).format(value);
}

function formatCost(cost: UsageCostOutcome): string {
  if (cost.amount_microusd === null) return "—";
  const cents = (BigInt(cost.amount_microusd) + 5_000n) / 10_000n;
  const amount = `${new Intl.NumberFormat(WEB_LOCALE).format(cents / 100n)}.${(cents % 100n).toString().padStart(2, "0")}`;
  return `${cost.status === "partial" ? "≥ " : ""}$${amount}`;
}

function costCoverage(cost: UsageCostOutcome): string {
  if (cost.status === "unavailable") return "Unpriced";
  const basis = cost.basis === "calculated" ? "estimated" : cost.basis;
  return cost.status === "complete" ? `${basis} · complete` : `${basis} · priced subset only`;
}

function formatDate(value: string): string {
  return new Intl.DateTimeFormat(WEB_LOCALE, { dateStyle: "medium", timeStyle: "short" }).format(
    new Date(value),
  );
}

function titleCase(value: string): string {
  return value.replaceAll("_", " ").replace(/\b\w/g, (character) => character.toUpperCase());
}

function text(id: string, value: string): void {
  requiredElement(id).textContent = value;
}

function requiredElement<T extends HTMLElement = HTMLElement>(id: string): T {
  const element = document.getElementById(id);
  if (!element) throw new Error(`Missing required element: ${id}`);
  return element as T;
}

async function hydrateHeader(): Promise<void> {
  try {
    const response = await fetch("/api/v2/account", {
      credentials: "same-origin",
      redirect: "error",
      headers: { Accept: "application/json" },
    });
    if (!response.ok) {
      showSignedOutHeader();
      return;
    }
    const parsed = AccountResponseSchema.safeParse(await response.json());
    if (!parsed.success) {
      showSignedOutHeader();
      return;
    }
    showSignedInHeader(parsed.data.account.display_label);
  } catch {
    showSignedOutHeader();
  }
}

function showSignedInHeader(displayLabel: string | null): void {
  const login = requiredElement<HTMLButtonElement>("header-login");
  const account = requiredElement("header-account");
  const name = requiredElement<HTMLAnchorElement>("header-account-name");
  login.hidden = true;
  account.hidden = false;
  name.textContent = displayLabel?.trim() || "Account";
}

function showSignedOutHeader(): void {
  requiredElement<HTMLButtonElement>("header-login").hidden = false;
  requiredElement("header-account").hidden = true;
}

async function beginWebLogin(returnTo: string): Promise<void> {
  try {
    const response = await fetch("/api/auth/v2/sign-in/social", {
      method: "POST",
      credentials: "same-origin",
      redirect: "error",
      headers: { Accept: "application/json", "Content-Type": "application/json" },
      body: JSON.stringify({ provider: "github", callbackURL: returnTo }),
    });
    const body = (await response.json()) as { url?: unknown };
    if (!response.ok || typeof body.url !== "string") throw new Error("login_failed");
    window.location.assign(body.url);
  } catch {
    window.alert("Quota could not start GitHub sign-in. Try again.");
  }
}

async function openAccountOrLogin(): Promise<void> {
  try {
    const response = await fetch("/api/v2/account", {
      credentials: "same-origin",
      redirect: "error",
      headers: { Accept: "application/json" },
    });
    switch (accountEntryAction(response.status)) {
      case "dashboard":
        window.location.assign(DASHBOARD_PATH);
        return;
      case "login":
        await beginWebLogin(DASHBOARD_PATH);
        return;
      case "error":
        throw new Error("account_probe_failed");
    }
  } catch {
    window.alert("Quota could not start GitHub sign-in. Try again.");
  }
}
