import type {
  BillingAgent,
  UsageCostMode as ProtocolUsageCostMode,
  UsageRow as ProtocolUsageRow,
  UsageUpload as ProtocolUsageUpload,
} from "@gotry-io/quota-protocol";
import type { DeviceWriterPrincipal } from "./account.ts";

export type UsageAgent = BillingAgent;
export type UsageRow = ProtocolUsageRow;
export type UsageUpload = ProtocolUsageUpload;
export type UsageCostMode = ProtocolUsageCostMode;

/**
 * What one upload did to the hours it named.
 *
 * Every named hour lands in exactly one list. `ignored` covers both an hour a newer scan already
 * replaced and an hour before this device's deletion watermark, because the device's next move is
 * the same either way: stop sending it.
 */
export type UsageWriteResult =
  | { outcome: "stale_device" }
  | { outcome: "written"; accepted: string[]; ignored: string[] };

/**
 * One identity's Usage rolled up to a UTC day, which is the only grain a managed read folds.
 *
 * `partial_hours` counts the hours behind this row whose scan came up short, so a period reports
 * `partial` without the read reaching back into `usage_hourly`.
 */
export interface StoredUsageDailyRow extends UsageRow {
  device_id: string;
  date: string;
  partial_hours: number;
}

export interface UsageDailyQuery {
  /** Inclusive UTC dates. Both absent asks for every retained day. */
  from?: string;
  to?: string;
  limit: number;
}

export interface UsageDailyResult {
  rows: StoredUsageDailyRow[];
  truncated: boolean;
}

export interface UsageState {
  recordUsage(
    principal: DeviceWriterPrincipal,
    upload: UsageUpload,
    receivedAt: string,
  ): Promise<UsageWriteResult>;
  queryDailyUsage(accountId: string, query: UsageDailyQuery): Promise<UsageDailyResult>;
}
