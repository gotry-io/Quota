import type { AccountSummaryRead } from "@gotry-io/quota-protocol";
import { cleanup, render } from "@testing-library/svelte";
import { afterEach, expect, it } from "vitest";
import QuotaBand from "./QuotaBand.svelte";

afterEach(cleanup);

type Subscription = AccountSummaryRead["subscriptions"][number];
type Window = Subscription["snapshot"]["windows"][number];

const NOW = new Date("2026-09-26T12:00:00Z");
const RESET = "2026-09-26T15:00:00Z";

function subscription(
  provider: string,
  windows: Window[],
  status: Subscription["snapshot"]["status"] = "available",
): Subscription {
  return {
    key: `${provider}|${provider}_account|global|`,
    provider,
    snapshot: {
      provider,
      account: { fingerprint: `${provider}_account`, fingerprint_scope: "global" },
      windows,
      status,
      observed_at: "2026-09-26T11:59:00Z",
    },
    sources: [{ device_id: "device_1", observed_at: "2026-09-26T11:59:00Z" }],
  } as Subscription;
}

function items(subscriptions: Subscription[]): Record<string, string> {
  const { container } = render(QuotaBand, {
    subscriptions,
    selectors: { [subscriptions[0]?.key ?? ""]: "0123456789ab" },
    now: NOW,
  });
  return Object.fromEntries(
    [...container.querySelectorAll("[data-provider]")].map((item) => [
      item.getAttribute("data-provider") ?? "",
      (item.textContent ?? "").replace(/\s+/g, " ").trim(),
    ]),
  );
}

it("speaks for a subscription with its tightest window, a wallet, or why it is not current", () => {
  const band = items([
    subscription("codex", [
      { id: "session", title: "5h", used_percent: 20, resets_at: RESET },
      { id: "weekly", title: "Weekly", used_percent: 88, resets_at: RESET },
    ]),
    subscription("openrouter", [
      {
        id: "balance",
        title: "Balance",
        used_percent: 0,
        remaining_value: 12.34,
        value_unit: "usd",
      },
    ]),
    subscription(
      "claude",
      [{ id: "session", title: "5h", used_percent: 10, resets_at: RESET }],
      "auth_required",
    ),
    subscription("cursor", [
      { id: "auto", title: "Auto", used_percent: 40, resets_at: RESET },
      {
        id: "included",
        title: "Included Usage",
        used_percent: 72.75,
        resets_at: RESET,
        remaining_value: 5.45,
        limit_value: 20,
        value_unit: "usd",
      },
    ]),
  ]);

  expect(band.codex).toBe("Codex 12% Weekly");
  expect(band.openrouter).toBe("OpenRouter $12.34");
  // A reading that no longer describes the account names why rather than printing its number.
  expect(band.claude).toBe("Claude Code Sign-in needed");
  // Dollars of a limit state that amount and draw no meter, so they never compete (TightestWindow).
  expect(band.cursor).toBe("Cursor 60% Auto");
});
