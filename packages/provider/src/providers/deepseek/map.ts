import type { QuotaSnapshot, QuotaWindow } from "@gotry-io/quota-protocol";
import type { ApiKeyCredentials } from "../../api-key/resolve.ts";
import { asRecord, readNumber, readString } from "../../runtime/files.ts";
import { accountIdentity, sha256Hex } from "../../runtime/identity.ts";
import { toIsoOffset } from "../../runtime/time.ts";

export const DEEPSEEK_SOURCE_API = "deepseek_balance_api";

export interface DeepSeekBalanceData {
  currency: string;
  /** Remaining total balance (paid + granted). */
  totalBalance: number;
  grantedBalance?: number;
  toppedUpBalance?: number;
  isAvailable: boolean;
}

/**
 * Parse every `balance_infos` row. Amounts may be string or number.
 * Callers should prefer positive balances (USD may be 0 while CNY is not).
 */
export function mapDeepSeekBalanceResponse(json: unknown): DeepSeekBalanceData[] | undefined {
  const root = asRecord(json);
  if (!root) {
    return undefined;
  }

  const isAvailable = root.is_available === true || root.isAvailable === true;
  const infos = root.balance_infos ?? root.balanceInfos;
  if (!Array.isArray(infos) || infos.length === 0) {
    return undefined;
  }

  const parsed: DeepSeekBalanceData[] = [];
  for (const entry of infos) {
    const record = asRecord(entry);
    if (!record) {
      continue;
    }
    const currency = (readString(record, "currency") ?? "USD").toUpperCase();
    const total = readFlexibleAmount(record, "total_balance", "totalBalance");
    if (total === undefined || !Number.isFinite(total) || total < 0) {
      continue;
    }
    const granted = readFlexibleAmount(record, "granted_balance", "grantedBalance");
    const toppedUp = readFlexibleAmount(record, "topped_up_balance", "toppedUpBalance");
    parsed.push({
      currency,
      totalBalance: total,
      isAvailable,
      ...(granted !== undefined ? { grantedBalance: granted } : {}),
      ...(toppedUp !== undefined ? { toppedUpBalance: toppedUp } : {}),
    });
  }

  return parsed.length > 0 ? parsed : undefined;
}

/**
 * Absolute remaining credit windows from `total_balance`.
 * - Prefer every currency with remaining > 0 (so USD=0 does not hide CNY).
 * - If all zero, still show one zero row (USD preferred) so the account is visible.
 * No budget ceiling — UI treats these as balance-only (no percent meter).
 */
export function mapDeepSeekWindows(balances: DeepSeekBalanceData[]): QuotaWindow[] {
  if (balances.length === 0) {
    return [];
  }
  const positive = balances.filter((item) => item.totalBalance > 0);
  const selected =
    positive.length > 0
      ? sortBalances(positive)
      : [balances.find((item) => item.currency === "USD") ?? balances[0]!];

  return selected.map(balanceWindow);
}

export function buildDeepSeekSnapshot(input: {
  windows: QuotaWindow[];
  credentials: ApiKeyCredentials;
  now?: Date;
}): QuotaSnapshot {
  const now = input.now ?? new Date();
  const keyFingerprint = sha256Hex(input.credentials.apiKey);
  const identity = accountIdentity("deepseek", "api_key", keyFingerprint);

  return {
    provider: "deepseek",
    account: {
      fingerprint: identity.fingerprint,
      fingerprint_scope: identity.scope,
      label: input.credentials.label,
      plan: "Credits",
    },
    windows: input.windows,
    source: DEEPSEEK_SOURCE_API,
    status: "available",
    observed_at: toIsoOffset(now),
  };
}

function balanceWindow(balance: DeepSeekBalanceData): QuotaWindow {
  const isUsd = balance.currency === "USD";
  return {
    id: isUsd ? "balance" : `balance_${balance.currency.toLowerCase()}`,
    title: isUsd ? "Balance (USD)" : `Balance (${balance.currency})`,
    used_percent: 0,
    remaining_value: balance.totalBalance,
    ...(isUsd ? { value_unit: "usd" as const } : {}),
  };
}

/** USD first, then alphabetical currency codes. */
function sortBalances(balances: DeepSeekBalanceData[]): DeepSeekBalanceData[] {
  return balances.slice().sort((a, b) => {
    if (a.currency === "USD") {
      return -1;
    }
    if (b.currency === "USD") {
      return 1;
    }
    return a.currency.localeCompare(b.currency);
  });
}

function readFlexibleAmount(
  record: Record<string, unknown>,
  ...keys: string[]
): number | undefined {
  for (const key of keys) {
    const fromNumber = readNumber(record, key);
    if (fromNumber !== undefined && Number.isFinite(fromNumber)) {
      return fromNumber;
    }
    const asString = readString(record, key);
    if (asString !== undefined) {
      const parsed = Number(asString);
      if (Number.isFinite(parsed)) {
        return parsed;
      }
    }
  }
  return undefined;
}
