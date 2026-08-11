import type {
  BillingAgent,
  CoverageStatus,
  UsageCostMode as ProtocolUsageCostMode,
  UsageCoverage as ProtocolUsageCoverage,
  UsageHourlyFact as ProtocolUsageHourlyFact,
  UsageSubmissionV2,
} from "@gotry-io/quota-protocol";
import type { DevicePrincipal } from "./account.ts";

export type UsageAgent = BillingAgent;
export type UsageCoverageStatus = CoverageStatus;
export type UsageCoverage = ProtocolUsageCoverage;
export type UsageHourlyFact = ProtocolUsageHourlyFact;
export type UsageSubmission = UsageSubmissionV2;

export type UsageWriteResult =
  | {
      outcome: "accepted" | "duplicate";
      usage_sync_revision: number;
      next_sequence: number;
    }
  | {
      outcome: "partial" | "sequence_conflict" | "stale_device" | "deleted_range";
    };

export type UsageCostMode = ProtocolUsageCostMode;

export interface UsageQuery {
  device_id?: string;
  agents?: readonly UsageAgent[];
  start_at?: string;
  end_at?: string;
  from?: string;
  to?: string;
  limit: number;
}

export interface StoredUsageCoverage {
  device_id: string;
  agent: UsageAgent;
  start_at: string;
  end_at: string;
  status: UsageCoverageStatus;
  parser_revision: string;
  accepted_at: string;
}

export interface StoredUsageHourlyFact extends UsageHourlyFact {
  device_id: string;
  aggregation_timezone: string;
}

export interface UsageQueryResult {
  rows: StoredUsageHourlyFact[];
  coverage: StoredUsageCoverage[];
  truncated: boolean;
  coverage_truncated?: boolean;
}

export interface UsageState {
  recordUsage(
    principal: DevicePrincipal,
    submission: UsageSubmission,
    receivedAt: string,
  ): Promise<UsageWriteResult>;
  queryAccountUsage(accountId: string, query: UsageQuery): Promise<UsageQueryResult>;
}
