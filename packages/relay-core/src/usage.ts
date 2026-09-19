import type {
  UsageRow as ProtocolUsageRow,
  UsageUpload as ProtocolUsageUpload,
} from "@gotry-io/quota-protocol";
import type { DeviceWriterPrincipal, LeaderboardRow } from "./account.ts";

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

/**
 * One identity's Usage over one stored UTC hour, rolled up across devices.
 *
 * `partial_hours` counts the scans behind this row that came up short, so a clock hour
 * reports incompleteness the same way a day does.
 */
export interface StoredUsageHourlyRow extends UsageRow {
  bucket_start_utc: string;
  partial_hours: number;
}

export interface UsageHourlyQuery {
  /** Inclusive `bucket_start_utc`. */
  from: string;
  /** Exclusive `bucket_start_utc`. */
  to: string;
  limit: number;
}

export interface UsageHourlyResult {
  rows: StoredUsageHourlyRow[];
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

/**
 * One local calendar day as a half-open UTC hour span, after the hour-grid rule.
 *
 * `start` is the first whole UTC hour of `date` in the request timezone; `end` is the first
 * whole UTC hour of the next local date. Adjacent days share no hour.
 */
export interface UsageLocalDayWindow {
  date: string;
  start: string;
  end: string;
}

export interface UsageLocalDayQuery {
  windows: readonly UsageLocalDayWindow[];
  limit: number;
}

/**
 * One pricing identity over one local date, rolled up across devices, hours, and agents.
 *
 * `date` is the local calendar date of the window that claimed these hours, not a UTC date.
 * `partial_hours` counts stored hours behind the row whose scan came up short.
 */
export interface StoredUsageLocalDayRow extends UsageRow {
  date: string;
  partial_hours: number;
}

export interface UsageLocalDayResult {
  rows: StoredUsageLocalDayRow[];
  truncated: boolean;
}

/** What the board asks the rollup for: one bounded window, and at most this many places. */
export interface LeaderboardQuery {
  /** Inclusive UTC date the window starts on. */
  from: string;
  limit: number;
}

export interface UsageState {
  recordUsage(
    principal: DeviceWriterPrincipal,
    upload: UsageUpload,
    receivedAt: string,
  ): Promise<UsageWriteResult>;
  queryDailyUsage(accountId: string, query: UsageDailyQuery): Promise<UsageDailyResult>;
  queryHourlyUsage(accountId: string, query: UsageHourlyQuery): Promise<UsageHourlyResult>;
  /**
   * The whole leaderboard, in one statement.
   *
   * The board is a ranking, so it is folded where the rows already are rather than read
   * profile by profile: a hundred places would otherwise be a hundred rollup scans, and the
   * answer is the same bytes for every reader
   * ([ADR 0045](../../../docs/decisions/0045-the-leaderboard-is-a-page-you-opt-into.md)).
   */
  queryLeaderboard(query: LeaderboardQuery): Promise<LeaderboardRow[]>;
  queryBoundaryHours(accountId: string, query: UsageBoundaryQuery): Promise<UsageBoundaryResult>;
  /**
   * Hours folded to one pricing identity per local date, in SQL.
   *
   * The caller supplies one hour-grid window per local date (a VALUES/CTE table). The scan
   * groups by that date plus the dimensions pricing reads, so a dense year returns hundreds of
   * rows rather than tens of thousands of hour-identity rows.
   */
  queryLocalDayUsage(accountId: string, query: UsageLocalDayQuery): Promise<UsageLocalDayResult>;
  readUsageFold(accountId: string, foldKey: string): Promise<string | null>;
  storeUsageFold(
    accountId: string,
    foldKey: string,
    usageJson: string,
    createdAt: string,
  ): Promise<void>;
}
