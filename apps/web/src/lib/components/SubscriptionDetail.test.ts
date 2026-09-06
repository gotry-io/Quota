import type { AccountSummaryRead } from "@gotry-io/quota-protocol";
import { cleanup, fireEvent, render, screen } from "@testing-library/svelte";
import { afterEach, expect, it, vi } from "vitest";
import { type AccountError, UNAVAILABLE_COPY } from "$lib/account-errors";
import SubscriptionDetail from "./SubscriptionDetail.svelte";

const SEL = "aabbccddeeff";
const FINGERPRINT = "codex_account_1";
const DEVICE_ID = "device_1";
const SECRET_DEVICE_ID = "device_secret";
const KEY = `codex|${FINGERPRINT}|global|`;

const emptyPeriod: AccountSummaryRead["usage"]["today"] = {
  totals: {
    total_tokens: 0,
    input_tokens: 0,
    output_tokens: 0,
    cache_read_input_tokens: 0,
    cache_write_input_tokens: 0,
    reasoning_tokens: 0,
    messages: 0,
  },
  cost: {
    mode: "auto",
    basis: "calculated",
    status: "complete",
    amount_microusd: "0",
    catalog_revision: "catalog_1",
    calculated_rows: 0,
    reported_rows: 0,
    unpriced_rows: 0,
    assumptions: [],
    unpriced: [],
  },
  partial: false,
  agents: [],
};

function makeSummary(
  overrides: Partial<Pick<AccountSummaryRead, "devices" | "subscriptions">> = {},
): AccountSummaryRead {
  return {
    protocol_version: 6,
    account: {
      account_id: "account_1",
      display_label: "Quota Tester",
      created_at: "2026-01-04T12:00:00Z",
    },
    devices: [
      {
        id: DEVICE_ID,
        display_name: "Studio",
        platform: "macos",
        last_seen_at: "2026-08-12T09:31:00Z",
        last_observed_at: "2026-08-12T09:30:00Z",
      },
      {
        id: "device_2",
        display_name: "Laptop",
        platform: "macos",
        last_seen_at: "2026-08-12T08:00:00Z",
        last_observed_at: "2026-08-12T08:00:00Z",
      },
    ],
    subscriptions: [codexSubscription()],
    usage: {
      today: emptyPeriod,
      last_7_days: emptyPeriod,
      last_30_days: emptyPeriod,
      all: emptyPeriod,
    },
    pricing_revision: "price_1",
    model_catalog_revision: "model_1",
    entitlement: {
      status: "none",
      expires_at: null,
      will_renew: false,
      product_id: null,
      store: null,
      stale: false,
    },
    ...overrides,
  };
}

function codexSubscription(): AccountSummaryRead["subscriptions"][number] {
  return {
    key: KEY,
    provider: "codex",
    snapshot: {
      provider: "codex",
      account: {
        fingerprint: FINGERPRINT,
        fingerprint_scope: "global",
        label: "k***@example.com",
        plan: "Plus",
      },
      windows: [
        {
          id: "weekly",
          title: "Weekly",
          used_percent: 42,
          resets_at: "2026-08-12T10:12:00Z",
          duration_seconds: 604_800,
        },
      ],
      status: "available",
      observed_at: "2026-08-12T09:30:00Z",
    },
    sources: [
      {
        device_id: SECRET_DEVICE_ID,
        observed_at: "2026-08-12T08:00:00Z",
        snapshot: {
          provider: "codex",
          account: {
            fingerprint: FINGERPRINT,
            fingerprint_scope: "global",
            plan: "Plus",
          },
          windows: [{ id: "weekly", title: "Weekly", used_percent: 70 }],
          status: "available",
          observed_at: "2026-08-12T08:00:00Z",
        },
      },
      {
        device_id: DEVICE_ID,
        observed_at: "2026-08-12T09:30:00Z",
      },
    ],
  };
}

function renderDetail(
  overrides: Partial<{
    sel: string;
    summary: AccountSummaryRead | null;
    loadError: AccountError | null;
    subscriptionSelectors: Record<string, string>;
    onRetry: () => void;
    now: Date;
  }> = {},
) {
  return render(SubscriptionDetail, {
    sel: SEL,
    summary: makeSummary(),
    loadError: null,
    subscriptionSelectors: { [KEY]: SEL },
    onRetry: vi.fn(),
    ...overrides,
  });
}

afterEach(() => {
  cleanup();
  vi.useRealTimers();
  vi.restoreAllMocks();
});

it("renders the matching subscription with windows, countdown, and Reporting", () => {
  vi.useFakeTimers({ toFake: ["Date", "setInterval", "clearInterval"] });
  vi.setSystemTime(new Date("2026-08-12T09:30:00Z"));

  const { container } = renderDetail();

  expect(screen.getByRole("heading", { name: "Codex" })).toBeTruthy();
  expect(screen.getByText("k***@example.com")).toBeTruthy();
  expect(screen.getByText("Plus")).toBeTruthy();
  expect(screen.getByText("Weekly")).toBeTruthy();
  expect(screen.getByText("Resets in 42m")).toBeTruthy();
  expect(screen.getByText("Reporting")).toBeTruthy();
  expect(container.textContent).toContain("Studio · 58%");
  expect(container.textContent).toContain("Device · 30%");
  const lines = [...container.querySelectorAll(".subscription-source-list li")].map(
    (item) => item.textContent,
  );
  expect(lines[0]).toContain("Studio");
  expect(lines[0]).toContain("Reporting");
  expect(lines[1]).toContain("Device");
  expect(lines[1]).not.toContain("Reporting");
  expect(container.textContent).not.toContain(FINGERPRINT);
  expect(container.textContent).not.toContain(DEVICE_ID);
  expect(container.textContent).not.toContain(SECRET_DEVICE_ID);
  expect(container.textContent).not.toContain(KEY);
  expect(screen.getByRole("link", { name: "← Overview" }).getAttribute("href")).toBe("/my");
});

it("still matches after a newer subscription is inserted first", () => {
  vi.useFakeTimers({ toFake: ["Date", "setInterval", "clearInterval"] });
  vi.setSystemTime(new Date("2026-08-12T09:30:00Z"));

  const leading = {
    key: "grok|grok_account_1|global|",
    provider: "grok" as const,
    snapshot: {
      provider: "grok" as const,
      account: {
        fingerprint: "grok_account_1",
        fingerprint_scope: "global" as const,
        plan: "SuperGrok",
      },
      windows: [{ id: "weekly", title: "Weekly", used_percent: 10 }],
      status: "available" as const,
      observed_at: "2026-08-12T09:30:00Z",
    },
    sources: [{ device_id: DEVICE_ID, observed_at: "2026-08-12T09:30:00Z" }],
  };

  renderDetail({
    summary: makeSummary({ subscriptions: [leading, codexSubscription()] }),
    subscriptionSelectors: {
      [leading.key]: "111111111111",
      [KEY]: SEL,
    },
  });

  expect(screen.getByRole("heading", { name: "Codex" })).toBeTruthy();
  expect(screen.queryByRole("heading", { name: "Grok" })).toBeNull();
});

it("says the subscription is no longer reported when the selector misses", () => {
  renderDetail({ sel: "deadbeef0000" });

  expect(screen.getByText("This subscription is no longer reported.")).toBeTruthy();
  expect(screen.queryByText("Weekly")).toBeNull();
  expect(screen.queryByText("Reporting")).toBeNull();
  expect(screen.getByRole("link", { name: "← Overview" })).toBeTruthy();
});

it("shows a loading skeleton before the summary arrives", () => {
  const { container } = renderDetail({ summary: null });

  const block = container.querySelector("[aria-busy='true']");
  expect(block).not.toBeNull();
  expect(block?.getAttribute("aria-label")).toBe("Loading subscription");
  expect(screen.queryByText("This subscription is no longer reported.")).toBeNull();
  expect(screen.queryByText("Weekly")).toBeNull();
});

it("shows Retry when the summary failed to load", () => {
  const onRetry = vi.fn();
  renderDetail({
    summary: null,
    loadError: {
      status: "unavailable",
      message: UNAVAILABLE_COPY,
      action: { type: "retry" },
    },
    onRetry,
  });

  expect(screen.getByRole("alert").textContent).toContain(UNAVAILABLE_COPY);
  fireEvent.click(screen.getByRole("button", { name: "Retry" }));
  expect(onRetry).toHaveBeenCalledTimes(1);
  expect(screen.queryByText("Weekly")).toBeNull();
});

it("refreshes the reset countdown when the shared now advances", () => {
  const summary = makeSummary();
  const { rerender } = renderDetail({
    summary,
    now: new Date("2026-08-12T09:30:00Z"),
  });
  expect(screen.getByText("Resets in 42m")).toBeTruthy();

  rerender({
    sel: SEL,
    summary,
    loadError: null,
    subscriptionSelectors: { [KEY]: SEL },
    onRetry: vi.fn(),
    now: new Date("2026-08-12T09:31:00Z"),
  });
  expect(screen.getByText("Resets in 41m")).toBeTruthy();
  expect(screen.queryByText("Resets in 42m")).toBeNull();
});

it("prints no Resets line once the refill instant has passed", () => {
  vi.useFakeTimers({ toFake: ["Date", "setInterval", "clearInterval"] });
  vi.setSystemTime(new Date("2026-08-12T09:30:00Z"));

  const subscription = codexSubscription();
  subscription.snapshot.windows = [
    {
      id: "weekly",
      title: "Weekly",
      used_percent: 42,
      resets_at: "2026-08-12T09:00:00Z",
      duration_seconds: 604_800,
    },
  ];

  renderDetail({ summary: makeSummary({ subscriptions: [subscription] }) });

  expect(screen.getByText("Weekly")).toBeTruthy();
  expect(screen.queryByText(/Resets/)).toBeNull();
});
