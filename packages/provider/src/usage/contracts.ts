import type {
  BillingAgent,
  BillingChannel,
  ChannelSource,
  ContextBucket,
} from "@gotry-io/quota-protocol";

export type UsageAgent = BillingAgent;
export type UsageChannelSource = ChannelSource;
export type { BillingChannel, ContextBucket };

export interface NormalizedUsageEvent {
  occurred_at: string;
  agent: UsageAgent;
  model: string;
  billing_channel: BillingChannel;
  channel_source: UsageChannelSource;
  input_tokens: number;
  cache_read_tokens: number;
  cache_write_5m_tokens: number;
  cache_write_1h_tokens: number;
  cache_write_inferred_tokens: number;
  output_tokens: number;
  reasoning_tokens: number;
  requests: number;
  context_bucket: ContextBucket;
  service_tier: string;
  speed: string;
  inference_geo: string;
  billable_tools: Partial<Record<"web_search" | "web_fetch", number>>;
  source_cost_microusd?: bigint;
  source_cost_covered_requests: number;
}

export type CoverageReasonCode =
  | "permission_denied"
  | "source_unreadable"
  | "source_changed"
  | "discovery_limit"
  | "record_limit"
  | "line_too_large"
  | "truncated_tail"
  | "malformed_json"
  | "unknown_record"
  | "invalid_timestamp"
  | "invalid_model"
  | "invalid_usage"
  | "scan_cancelled";

export interface CoverageReason {
  code: CoverageReasonCode;
}

export interface ScanCoverage {
  agent: UsageAgent;
  start_at: string;
  end_at: string;
  status: "complete" | "partial";
  reasons: readonly CoverageReason[];
}

/** Opaque local-cache cursor. It contains neither a source path nor a provider session id. */
export interface UsageSourceCursor {
  source_file_id: string;
  byte_offset: number;
  record_hash: string;
}

export interface NormalizedUsageRecord {
  event: NormalizedUsageEvent;
  cursor: UsageSourceCursor;
}

export interface UsageScanResult {
  records: readonly NormalizedUsageRecord[];
  coverage: ScanCoverage;
  scanned_source_count: number;
}

/** Local-only discovery output. Callers must not upload or export `path`. */
export interface LocalUsageFile {
  path: string;
  source_file_id: string;
  size: number;
  modified_ns: string;
  identity: string;
}

export interface UsageFileDiscoveryResult {
  files: readonly LocalUsageFile[];
  reasons: readonly CoverageReason[];
}

export interface UsageFileInfo {
  kind: "directory" | "file" | "other";
  size: number;
  device: string;
  inode: string;
  birthtime_ns: string;
  modified_ns: string;
}

export interface UsageDirectoryEntry {
  name: string;
  kind: "directory" | "file" | "other";
}

export interface UsageFileSystem {
  stat(path: string): Promise<UsageFileInfo>;
  readDirectory(path: string): Promise<readonly UsageDirectoryEntry[]>;
  readChunks(path: string, signal?: AbortSignal): AsyncIterable<Uint8Array>;
}

export interface UsageDiscoveryOptions {
  homeDirectory?: string;
  environment?: Readonly<Record<string, string | undefined>>;
  roots?: readonly string[];
  fileSystem?: UsageFileSystem;
}

export interface UsageScanOptions extends UsageDiscoveryOptions {
  startAt: string;
  endAt: string;
  signal?: AbortSignal;
}
