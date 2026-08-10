import { createHash } from "node:crypto";
import { createRequire } from "node:module";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import { UtcHourSchema } from "@gotry-io/quota-protocol";
import type {
  BillingChannel,
  CoverageReason,
  LocalUsageFile,
  NormalizedUsageRecord,
  UsageDiscoveryOptions,
  UsageFileDiscoveryResult,
  UsageFileSystem,
  UsageScanOptions,
  UsageScanResult,
  UsageSourceCursor,
} from "../../usage/contracts.ts";
import {
  boundedModel,
  contextBucket,
  defaultUsageFileSystem,
  discoverUsageFiles,
  record,
  safeCount,
  safeSum,
  scanUsageFiles,
  type UsageLineParser,
} from "../../usage/local.ts";

const MAXIMUM_OPENCODE_ROWS = 2_000_000;

export function openCodeUsageRoots(options: UsageDiscoveryOptions = {}): string[] {
  if (options.roots) return [...options.roots];
  const home = options.homeDirectory ?? homedir();
  const dataHome = options.environment?.XDG_DATA_HOME?.trim() || join(home, ".local", "share");
  return [join(dataHome, "opencode")];
}

export async function discoverOpenCodeUsageFiles(
  options: UsageDiscoveryOptions = {},
): Promise<UsageFileDiscoveryResult> {
  const roots = openCodeUsageRoots(options);
  const databaseDiscovery = await discoverUsageFiles({
    agent: "opencode",
    roots: roots.map((root) =>
      basename(root) === "opencode.db" ? root : join(root, "opencode.db"),
    ),
    ...(options.fileSystem ? { fileSystem: options.fileSystem } : {}),
    acceptsFile: (path) => basename(path) === "opencode.db",
  });
  if (databaseDiscovery.files.length > 0 || databaseDiscovery.reasons.length > 0) {
    return databaseDiscovery;
  }
  return await discoverUsageFiles({
    agent: "opencode",
    roots: options.roots ? roots : roots.map((root) => join(root, "storage", "message")),
    ...(options.fileSystem ? { fileSystem: options.fileSystem } : {}),
    acceptsFile: (path) => path.endsWith(".json"),
  });
}

export async function scanOpenCodeUsage(options: UsageScanOptions): Promise<UsageScanResult> {
  const discovery = await discoverOpenCodeUsageFiles(options);
  return discovery.files.some((file) => basename(file.path) === "opencode.db")
    ? await scanDatabases(options, discovery)
    : await scanUsageFiles({
        agent: "opencode",
        startAt: options.startAt,
        endAt: options.endAt,
        discovery,
        ...(options.signal ? { signal: options.signal } : {}),
        ...(options.fileSystem ? { fileSystem: options.fileSystem } : {}),
        createParser: () => new OpenCodeUsageParser(),
      });
}

export type OpenCodeUsageFile = LocalUsageFile;

class OpenCodeUsageParser implements UsageLineParser {
  parse(
    value: Record<string, unknown>,
    cursor: UsageSourceCursor,
  ): {
    records?: readonly NormalizedUsageRecord[];
    reason?: "invalid_timestamp" | "invalid_model" | "invalid_usage";
  } {
    if (value.role !== "assistant") return {};
    if (value.modelID === "unknown") return {};
    const model = boundedModel(value.modelID);
    if (!model) return { reason: "invalid_model" };
    const time = record(value.time);
    const occurredAt = millisecondInstant(time?.completed ?? time?.created);
    if (!occurredAt) return { reason: "invalid_timestamp" };
    const tokens = record(value.tokens);
    const cache = record(tokens?.cache);
    const parsed = tokens && cache ? parseTokens(tokens, cache) : undefined;
    if (!parsed) return { reason: "invalid_usage" };
    const sourceCost = sourceCostMicrousd(value.cost);
    if (sourceCost.invalid) return { reason: "invalid_usage" };
    if (parsed.input === 0 && parsed.output === 0 && sourceCost.microusd === undefined) return {};
    const channel = providerBillingChannel(value.providerID);
    return {
      records: [
        {
          cursor,
          event: {
            occurred_at: occurredAt,
            agent: "opencode",
            model,
            billing_channel: channel,
            channel_source: channel === "unknown" ? "unknown" : "explicit",
            input_tokens: parsed.input,
            cache_read_tokens: parsed.cacheRead,
            cache_write_5m_tokens: 0,
            cache_write_1h_tokens: 0,
            cache_write_inferred_tokens: parsed.cacheWrite,
            output_tokens: parsed.output,
            reasoning_tokens: parsed.reasoning,
            requests: 1,
            context_bucket: contextBucket(parsed.input),
            service_tier: "unknown",
            speed: "unknown",
            inference_geo: "unknown",
            billable_tools: {},
            ...(sourceCost.microusd === undefined
              ? {}
              : { source_cost_microusd: sourceCost.microusd }),
            source_cost_covered_requests: sourceCost.microusd === undefined ? 0 : 1,
          },
        },
      ],
    };
  }
}

async function scanDatabases(
  options: UsageScanOptions,
  discovery: UsageFileDiscoveryResult,
): Promise<UsageScanResult> {
  const start = parseBoundary(options.startAt);
  const end = parseBoundary(options.endAt);
  if (start >= end) throw new TypeError("Usage scan range must be increasing.");
  const fileSystem = options.fileSystem ?? defaultUsageFileSystem;
  const records: NormalizedUsageRecord[] = [];
  const reasons: CoverageReason[] = [...discovery.reasons];
  let scannedSourceCount = 0;
  let rowsSeen = 0;

  for (const file of discovery.files) {
    if (options.signal?.aborted) {
      reasons.push({ code: "scan_cancelled" });
      break;
    }
    const before = await databaseInfo(fileSystem, file, reasons);
    if (!before) continue;
    scannedSourceCount += 1;
    try {
      const parser = new OpenCodeUsageParser();
      let index = 0;
      for (const row of queryDatabase(file.path)) {
        rowsSeen += 1;
        if (rowsSeen > MAXIMUM_OPENCODE_ROWS) {
          reasons.push({ code: "record_limit" });
          break;
        }
        const cursor = {
          source_file_id: file.source_file_id,
          byte_offset: index,
          record_hash: sha256(String(row.id ?? index)),
        } satisfies UsageSourceCursor;
        const parsed = parser.parse(databaseMessage(row), cursor);
        if (parsed.reason) reasons.push({ code: parsed.reason });
        for (const item of parsed.records ?? []) {
          const occurredAt = Date.parse(item.event.occurred_at);
          if (occurredAt >= start && occurredAt < end) records.push(item);
        }
        index += 1;
      }
    } catch (error) {
      reasons.push({ code: readErrorReason(error) });
    }
    const after = await databaseInfo(fileSystem, file, reasons);
    if (after && (after.size !== before.size || after.modified_ns !== before.modified_ns)) {
      reasons.push({ code: "source_changed" });
    }
  }

  return {
    records,
    scanned_source_count: scannedSourceCount,
    coverage: {
      agent: "opencode",
      start_at: options.startAt,
      end_at: options.endAt,
      status: reasons.length === 0 ? "complete" : "partial",
      reasons: reasons.slice(0, 128),
    },
  };
}

const DATABASE_QUERY = `
  SELECT
    id,
    json_extract(data, '$.role') AS role,
    json_extract(data, '$.modelID') AS model_id,
    json_extract(data, '$.providerID') AS provider_id,
    json_extract(data, '$.time.created') AS created_at,
    json_extract(data, '$.time.completed') AS completed_at,
    json_extract(data, '$.tokens.input') AS input_tokens,
    json_extract(data, '$.tokens.output') AS output_tokens,
    json_extract(data, '$.tokens.reasoning') AS reasoning_tokens,
    json_extract(data, '$.tokens.cache.read') AS cache_read_tokens,
    json_extract(data, '$.tokens.cache.write') AS cache_write_tokens,
    json_extract(data, '$.cost') AS cost
  FROM message
  WHERE json_extract(data, '$.role') = 'assistant'
  ORDER BY time_created, id
`;

function* queryDatabase(path: string): Generator<Record<string, unknown>> {
  const runtimeRequire = createRequire(import.meta.url);
  if (process.versions.bun) {
    const module = runtimeRequire("bun:sqlite") as {
      Database: new (
        path: string,
        options: { readonly: boolean },
      ) => {
        query(sql: string): { iterate(): IterableIterator<Record<string, unknown>> };
        close(): void;
      };
    };
    const database = new module.Database(path, { readonly: true });
    try {
      yield* database.query(DATABASE_QUERY).iterate();
    } finally {
      database.close();
    }
    return;
  }
  const module = runtimeRequire("node:sqlite") as {
    DatabaseSync: new (
      path: string,
      options: { readOnly: boolean },
    ) => {
      prepare(sql: string): { iterate(): IterableIterator<Record<string, unknown>> };
      close(): void;
    };
  };
  const database = new module.DatabaseSync(path, { readOnly: true });
  try {
    yield* database.prepare(DATABASE_QUERY).iterate();
  } finally {
    database.close();
  }
}

function databaseMessage(row: Record<string, unknown>): Record<string, unknown> {
  return {
    role: row.role,
    modelID: row.model_id,
    providerID: row.provider_id,
    time: { created: row.created_at, completed: row.completed_at },
    tokens: {
      input: row.input_tokens,
      output: row.output_tokens,
      reasoning: row.reasoning_tokens,
      cache: { read: row.cache_read_tokens, write: row.cache_write_tokens },
    },
    cost: row.cost,
  };
}

function parseTokens(tokens: Record<string, unknown>, cache: Record<string, unknown>) {
  const uncachedInput = safeCount(tokens.input);
  const output = safeCount(tokens.output);
  const reasoning = safeCount(tokens.reasoning);
  const cacheRead = safeCount(cache.read);
  const cacheWrite = safeCount(cache.write);
  if (
    uncachedInput === undefined ||
    output === undefined ||
    reasoning === undefined ||
    cacheRead === undefined ||
    cacheWrite === undefined ||
    reasoning > output
  ) {
    return undefined;
  }
  const input = safeSum(uncachedInput, cacheRead, cacheWrite);
  return input === undefined ? undefined : { input, output, reasoning, cacheRead, cacheWrite };
}

function millisecondInstant(value: unknown): string | undefined {
  const milliseconds = safeCount(value);
  if (milliseconds === undefined) return undefined;
  const instant = new Date(milliseconds);
  return Number.isNaN(instant.getTime()) ? undefined : instant.toISOString();
}

function sourceCostMicrousd(value: unknown): { microusd?: bigint; invalid: boolean } {
  if (value === undefined || value === null || value === 0) return { invalid: false };
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0) return { invalid: true };
  const microusd = Math.round(value * 1_000_000);
  return Number.isSafeInteger(microusd)
    ? { microusd: BigInt(microusd), invalid: false }
    : { invalid: true };
}

function providerBillingChannel(provider: unknown): BillingChannel {
  switch (provider) {
    case "openai":
      return "openai_direct";
    case "anthropic":
      return "anthropic_direct";
    case "azure-openai":
      return "azure_openai";
    case "amazon-bedrock":
    case "bedrock":
      return "aws_bedrock";
    case "google-vertex":
      return "google_vertex";
    case "openrouter":
      return "openrouter";
    case "xai":
      return "xai_direct";
    default:
      return "unknown";
  }
}

async function databaseInfo(
  fileSystem: UsageFileSystem,
  file: LocalUsageFile,
  reasons: CoverageReason[],
) {
  try {
    const info = await fileSystem.stat(file.path);
    if (info.kind !== "file") {
      reasons.push({ code: "source_changed" });
      return undefined;
    }
    return info;
  } catch (error) {
    reasons.push({ code: readErrorReason(error) });
    return undefined;
  }
}

function readErrorReason(error: unknown): "permission_denied" | "source_unreadable" {
  const code = error && typeof error === "object" && "code" in error ? error.code : undefined;
  return code === "EACCES" || code === "EPERM" ? "permission_denied" : "source_unreadable";
}

function parseBoundary(value: string): number {
  const parsed = UtcHourSchema.safeParse(value);
  if (!parsed.success) throw new TypeError("Usage scan range must use canonical UTC hours.");
  return Date.parse(parsed.data);
}

function sha256(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}
