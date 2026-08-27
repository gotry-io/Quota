import type {
  UsageRow as ProtocolUsageRow,
  UsageUpload as ProtocolUsageUpload,
} from "@gotry-io/quota-protocol";
import type { DeviceWriterPrincipal } from "./account.ts";

export type UsageRow = ProtocolUsageRow;
export type UsageUpload = ProtocolUsageUpload;

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
 * One identity's Usage over a UTC day, or over the part of one a local period's edge cuts out.
 *
 * `partial_hours` counts the hours behind this row whose scan came up short, so a period reports
 * `partial` from the rows it folded rather than from a second read.
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

/** A half-open range of whole UTC hours, named the way `usage_hourly` keys them. */
export interface UsageHourRange {
  /** Inclusive `bucket_start_utc`. */
  from: string;
  /** Exclusive `bucket_start_utc`. */
  to: string;
}

/**
 * The hours a local period's edge cuts out of a UTC day.
 *
 * A local day begins at local midnight, which lands inside a UTC day for most of the world, so
 * the day at each edge of a period cannot be read from the rollup. Every whole UTC day between
 * the edges still can, which is what keeps this read off the hourly history.
 */
export interface UsageBoundaryQuery {
  ranges: readonly UsageHourRange[];
  limit: number;
}

export interface UsageBoundaryResult {
  /** The rows of each requested range, rolled up to a UTC day, in the order they were asked for. */
  ranges: StoredUsageDailyRow[][];
  truncated: boolean;
}

export interface UsageState {
  recordUsage(
    principal: DeviceWriterPrincipal,
    upload: UsageUpload,
    receivedAt: string,
  ): Promise<UsageWriteResult>;
  queryDailyUsage(accountId: string, query: UsageDailyQuery): Promise<UsageDailyResult>;
  queryBoundaryHours(accountId: string, query: UsageBoundaryQuery): Promise<UsageBoundaryResult>;
}
