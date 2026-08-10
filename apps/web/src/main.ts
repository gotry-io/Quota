import {
  type AccountDevice,
  type AccountSummary,
  AccountSummarySchema,
  DeviceAuthorizationDecisionRequestSchema,
  PROTOCOL_VERSION,
  type UsageBreakdown,
  type UsageCostOutcome,
} from "@gotry-io/quota-protocol";
import "./styles.css";

const year = document.querySelector<HTMLElement>("#copyright-year");
if (year) year.textContent = String(new Date().getFullYear());
for (const button of document.querySelectorAll<HTMLButtonElement>("[data-web-login]")) {
  button.addEventListener("click", () => {
    void beginWebLogin("/app");
  });
}
document.querySelector<HTMLFormElement>("#logout-form")?.addEventListener("submit", (event) => {
  event.preventDefault();
  void logout();
});
document.querySelector<HTMLButtonElement>("#delete-account")?.addEventListener("click", () => {
  void deleteAccount();
});

const path = window.location.pathname;
if (path === "/app" || path.startsWith("/app/")) {
  void showDashboard();
} else if (path === "/activate") {
  showActivation();
}

async function showDashboard(): Promise<void> {
  setView("dashboard-view");
  try {
    const request = {
      credentials: "same-origin",
      redirect: "error",
      headers: { Accept: "application/json" },
    } satisfies RequestInit;
    const response = await fetch("/api/v2/account/summary?cost_mode=calculate", request);
    if (response.status === 401) {
      showAccountError("Continue with GitHub to see account devices and Usage.", "/app");
      return;
    }
    if (!response.ok) throw new Error("account_unavailable");
    const parsed = AccountSummarySchema.safeParse(await response.json());
    if (!parsed.success) throw new Error("invalid_account_summary");
    renderDashboard(parsed.data);
  } catch {
    showAccountError("Quota could not load this account. Refresh to try again.");
  }
}

function renderDashboard(summary: AccountSummary): void {
  text("account-label", summary.account.display_label ?? "GitHub account");
  text("input-total", formatCount(summary.usage.totals.input_tokens));
  text("output-total", formatCount(summary.usage.totals.output_tokens));
  text("cost-total", formatCost(summary.usage.cost));
  text("cost-coverage", costCoverage(summary.usage.cost));
  text("device-count", String(summary.devices.length));

  const devices = requiredElement("device-list");
  devices.replaceChildren(...summary.devices.map(renderDevice));
  if (summary.devices.length === 0) {
    devices.append(emptyState("No devices yet. Sign in from QuotaCLI to add this installation."));
  }

  const breakdowns = summary.usage.breakdowns.filter((item) => item.dimension === "agent");
  const table = requiredElement("usage-breakdown");
  table.replaceChildren(...breakdowns.map(renderBreakdown));
  if (breakdowns.length === 0) {
    const row = document.createElement("tr");
    const cell = document.createElement("td");
    cell.colSpan = 4;
    cell.textContent = "No Usage has been synced for this range.";
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
      void beginWebLogin("/app");
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
      void beginWebLogin("/app");
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
    item.key === "claude_code" ? "Claude Code" : titleCase(item.key),
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
    showActivationStatus("Enter the exact code shown by QuotaCLI.");
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
        ? "Installation authorized. Return to QuotaCLI."
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

function setView(id: "dashboard-view" | "activate-view"): void {
  requiredElement("landing-view").hidden = true;
  requiredElement("dashboard-view").hidden = id !== "dashboard-view";
  requiredElement("activate-view").hidden = id !== "activate-view";
  requiredElement("route-loading").hidden = true;
}

function showAccountError(message: string, action?: string): void {
  const notice = requiredElement("account-error");
  notice.replaceChildren(document.createTextNode(message));
  if (action) {
    const button = document.createElement("button");
    button.className = "button button-primary notice-action";
    button.type = "button";
    button.textContent = "Continue with GitHub";
    button.addEventListener("click", () => {
      void beginWebLogin(action);
    });
    notice.append(button);
  }
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
  return new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 }).format(
    value,
  );
}

function formatCost(cost: UsageCostOutcome): string {
  if (cost.amount_microusd === null) return "—";
  const cents = (BigInt(cost.amount_microusd) + 5_000n) / 10_000n;
  const amount = `${new Intl.NumberFormat().format(cents / 100n)}.${(cents % 100n).toString().padStart(2, "0")}`;
  return `${cost.status === "partial" ? "≥ " : ""}$${amount}`;
}

function costCoverage(cost: UsageCostOutcome): string {
  if (cost.status === "unavailable") return "Unpriced";
  const basis = cost.basis === "calculated" ? "estimated" : cost.basis;
  return cost.status === "complete" ? `${basis} · complete` : `${basis} · priced subset only`;
}

function formatDate(value: string): string {
  return new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(
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
