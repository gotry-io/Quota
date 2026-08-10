import { homedir } from "node:os";
import { join } from "node:path";
import type {
  BillingChannel,
  LocalUsageFile,
  NormalizedUsageRecord,
  UsageDiscoveryOptions,
  UsageFileDiscoveryResult,
  UsageScanOptions,
  UsageScanResult,
  UsageSourceCursor,
} from "../../usage/contracts.ts";
import {
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

export function piUsageRoots(options: UsageDiscoveryOptions = {}): string[] {
  if (options.roots) return [...options.roots];
  const home = options.homeDirectory ?? homedir();
  const configured = options.environment?.PI_CODING_AGENT_DIR?.trim();
  return configured
    ? [join(configured, "sessions")]
    : [
        join(home, ".pi", "agent", "sessions"),
        join(home, ".local", "share", "pi-coding-agent", "sessions"),
      ];
}

export async function discoverPiUsageFiles(
  options: UsageDiscoveryOptions = {},
): Promise<UsageFileDiscoveryResult> {
  return await discoverUsageFiles({
    agent: "pi",
    roots: piUsageRoots(options),
    ...(options.fileSystem ? { fileSystem: options.fileSystem } : {}),
    acceptsFile: (path) => path.endsWith(".jsonl"),
  });
}

export async function scanPiUsage(options: UsageScanOptions): Promise<UsageScanResult> {
  const discovery = await discoverPiUsageFiles(options);
  return await scanUsageFiles({
    agent: "pi",
    startAt: options.startAt,
    endAt: options.endAt,
    discovery,
    ...(options.signal ? { signal: options.signal } : {}),
    ...(options.fileSystem ? { fileSystem: options.fileSystem } : {}),
    createParser: () => new PiUsageParser(),
  });
}

export type PiUsageFile = LocalUsageFile;

class PiUsageParser implements UsageLineParser {
  parse(
    value: Record<string, unknown>,
    cursor: UsageSourceCursor,
  ): {
    records?: readonly NormalizedUsageRecord[];
    reason?: "invalid_timestamp" | "invalid_model" | "invalid_usage";
  } {
    if (value.type !== "message") return {};
    const message = record(value.message);
    if (!message || message.role !== "assistant") return {};
    if (message.model === "unknown") return {};
    const model = boundedModel(message.model);
    if (!model) return { reason: "invalid_model" };
    const occurredAt = millisecondInstant(message.timestamp) ?? canonicalInstant(value.timestamp);
    if (!occurredAt) return { reason: "invalid_timestamp" };
    const usage = record(message.usage);
    if (!usage) return { reason: "invalid_usage" };
    const parsed = parseUsage(usage);
    if (!parsed) return { reason: "invalid_usage" };
    const sourceCost = sourceCostMicrousd(record(usage.cost)?.total);
    if (sourceCost.invalid) return { reason: "invalid_usage" };
    if (parsed.input === 0 && parsed.output === 0 && sourceCost.microusd === undefined) return {};
    const channel = billingChannel(message.provider);
    return {
      records: [
        {
          cursor,
          event: {
            occurred_at: occurredAt,
            agent: "pi",
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

function parseUsage(usage: Record<string, unknown>) {
  const uncachedInput = safeCount(usage.input);
  const output = safeCount(usage.output);
  const cacheRead = safeCount(usage.cacheRead);
  const cacheWrite = safeCount(usage.cacheWrite);
  const reasoning = usage.reasoning === undefined ? 0 : safeCount(usage.reasoning);
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

function billingChannel(provider: unknown): BillingChannel {
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
