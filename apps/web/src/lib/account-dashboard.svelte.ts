import { getContext, setContext } from "svelte";
import type { AccountSummaryRead } from "@gotry-io/quota-protocol";
import { type AccountError, fetchAccountSummary } from "./account-client.ts";
import { hashSelectorPreimage } from "./subscription-selector.ts";

const ACCOUNT_DASHBOARD = Symbol("account-dashboard");

export function createAccountDashboard() {
  let summary = $state<AccountSummaryRead | null>(null);
  let loadError = $state<AccountError | null>(null);
  let subscriptionSelectors = $state<Record<string, string>>({});

  async function loadSummary(): Promise<void> {
    const result = await fetchAccountSummary();
    if (result.status === "ok") {
      const selectors: Record<string, string> = {};
      for (const subscription of result.summary.subscriptions) {
        selectors[subscription.key] = await hashSelectorPreimage(subscription.key);
      }
      summary = result.summary;
      subscriptionSelectors = selectors;
      loadError = null;
      return;
    }
    loadError = result;
  }

  function setError(error: AccountError): void {
    loadError = error;
  }

  return {
    get summary() {
      return summary;
    },
    get loadError() {
      return loadError;
    },
    get subscriptionSelectors() {
      return subscriptionSelectors;
    },
    loadSummary,
    setError,
  };
}

export type AccountDashboard = ReturnType<typeof createAccountDashboard>;

export function setAccountDashboard(dashboard: AccountDashboard): void {
  setContext(ACCOUNT_DASHBOARD, dashboard);
}

export function getAccountDashboard(): AccountDashboard {
  return getContext(ACCOUNT_DASHBOARD);
}
