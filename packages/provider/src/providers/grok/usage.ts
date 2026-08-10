import { homedir } from "node:os";
import { join } from "node:path";
import type {
  LocalUsageFile,
  NormalizedUsageRecord,
  UsageDiscoveryOptions,
  UsageFileDiscoveryResult,
  UsageScanOptions,
  UsageScanResult,
  UsageSourceCursor,
} from "../../usage/contracts.ts";
import {
  boundedDimension,
  boundedModel,
  canonicalInstant,
  contextBucket,
  discoverUsageFiles,
  record,
  safeCount,
  safeSum,
  scanUsageFiles,
  type UsageLineParser,
} from "../../usage/local.ts";

export function grokUsageRoots(options: UsageDiscoveryOptions = {}): string[] {
  if (options.roots) return [...options.roots];
  const home = options.homeDirectory ?? homedir();
  const grokHome = options.environment?.GROK_HOME?.trim() || join(home, ".grok");
  return [join(grokHome, "sessions"), join(grokHome, "trace-exports")];
}

export async function discoverGrokUsageFiles(
  options: UsageDiscoveryOptions = {},
): Promise<UsageFileDiscoveryResult> {
  return await discoverUsageFiles({
    agent: "grok",
    roots: grokUsageRoots(options),
    ...(options.fileSystem ? { fileSystem: options.fileSystem } : {}),
    acceptsFile: (path) =>
      path.endsWith("events.jsonl") ||
      (path.includes("/trace-exports/") && path.endsWith(".jsonl")),
  });
}

export async function scanGrokUsage(options: UsageScanOptions): Promise<UsageScanResult> {
  const discovery = await discoverGrokUsageFiles(options);
  return await scanUsageFiles({
    agent: "grok",
    startAt: options.startAt,
    endAt: options.endAt,
    discovery,
    ...(options.signal ? { signal: options.signal } : {}),
    ...(options.fileSystem ? { fileSystem: options.fileSystem } : {}),
    createParser: () => new GrokUsageParser(),
  });
}

export type GrokUsageFile = LocalUsageFile;

class GrokUsageParser implements UsageLineParser {
  private model: string | undefined;
  private turnStartedAt: string | undefined;

  parse(
    value: Record<string, unknown>,
    cursor: UsageSourceCursor,
  ): {
    records?: readonly NormalizedUsageRecord[];
    reason?: "invalid_timestamp" | "invalid_model" | "invalid_usage";
  } {
    if (value.type === "turn_started") {
      this.turnStartedAt = canonicalInstant(value.ts);
      this.model = value.model_id === "unknown" ? undefined : boundedModel(value.model_id);
      return {};
    }
    if (value.type !== "usage") return {};
    const usage = record(value.usage);
    if (!usage) return { reason: "invalid_usage" };
    const explicitModel = value.model_id ?? value.model;
    if (explicitModel === "unknown") return {};
    const model = explicitModel === undefined ? this.model : boundedModel(explicitModel);
    if (!model) return {};
    const occurredAt = canonicalInstant(value.ts) ?? this.turnStartedAt;
    if (!occurredAt) return { reason: "invalid_timestamp" };
    const parsed = parseUsage(usage);
    if (!parsed) return { reason: "invalid_usage" };
    const sourceCost = exactCostMicrousd(usage.cost_in_usd_ticks);
    if (sourceCost.invalid) return { reason: "invalid_usage" };
    const tools = parseTools(usage.server_tool_use);
    if (!tools) return { reason: "invalid_usage" };
    if (
      parsed.input === 0 &&
      parsed.output === 0 &&
      Object.keys(tools).length === 0 &&
      sourceCost.microusd === undefined
    ) {
      return {};
    }
    return {
      records: [
        {
          cursor,
          event: {
            occurred_at: occurredAt,
            agent: "grok",
            model,
            billing_channel: "xai_direct",
            channel_source: "agent_default",
            input_tokens: parsed.input,
            cache_read_tokens: parsed.cacheRead,
            cache_write_5m_tokens: 0,
            cache_write_1h_tokens: 0,
            cache_write_inferred_tokens: parsed.cacheWrite,
            output_tokens: parsed.output,
            reasoning_tokens: parsed.reasoning,
            requests: 1,
            context_bucket: contextBucket(parsed.input),
            service_tier: optionalDimension(usage.service_tier),
            speed: "unknown",
            inference_geo: "unknown",
            billable_tools: tools,
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

function parseUsage(usage: Record<string, unknown>) {
  const uncachedInput = safeCount(usage.input_tokens);
  const output = safeCount(usage.output_tokens);
  const cacheRead = optionalCount(usage.cache_read_input_tokens);
  const cacheWrite = optionalCount(usage.cache_creation_input_tokens);
  const reasoning = optionalCount(usage.reasoning_tokens);
  if (
    uncachedInput === undefined ||
    output === undefined ||
    cacheRead === undefined ||
    cacheWrite === undefined ||
    reasoning === undefined ||
    reasoning > output
  ) {
    return undefined;
  }
  const input = safeSum(uncachedInput, cacheRead, cacheWrite);
  return input === undefined ? undefined : { input, output, cacheRead, cacheWrite, reasoning };
}

function parseTools(
  value: unknown,
): Partial<Record<"web_search" | "web_fetch", number>> | undefined {
  if (value === undefined || value === null) return {};
  const tools = record(value);
  if (!tools) return undefined;
  const webSearch = optionalCount(tools.web_search_requests);
  const webFetch = optionalCount(tools.web_fetch_requests);
  if (webSearch === undefined || webFetch === undefined) return undefined;
  return {
    ...(webSearch > 0 ? { web_search: webSearch } : {}),
    ...(webFetch > 0 ? { web_fetch: webFetch } : {}),
  };
}

function exactCostMicrousd(value: unknown): { microusd?: bigint; invalid: boolean } {
  if (value === undefined || value === null || value === 0 || value === "0") {
    return { invalid: false };
  }
  try {
    const ticks = BigInt(value as string | number | bigint);
    if (ticks < 0n) return { invalid: true };
    return { microusd: (ticks + 5_000n) / 10_000n, invalid: false };
  } catch {
    return { invalid: true };
  }
}

function optionalCount(value: unknown): number | undefined {
  return value === undefined || value === null ? 0 : safeCount(value);
}

function optionalDimension(value: unknown): string {
  return value === undefined || value === null || value === ""
    ? "unknown"
    : (boundedDimension(value) ?? "unknown");
}
