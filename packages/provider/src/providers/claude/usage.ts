import { homedir } from "node:os";
import { join } from "node:path";
import type {
  LocalUsageFile,
  NormalizedUsageEvent,
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

export function claudeUsageRoots(options: UsageDiscoveryOptions = {}): string[] {
  if (options.roots) {
    return [...options.roots];
  }
  const home = options.homeDirectory ?? homedir();
  const configRoot = options.environment?.CLAUDE_CONFIG_DIR?.trim() || join(home, ".claude");
  return [join(configRoot, "projects")];
}

export async function discoverClaudeUsageFiles(
  options: UsageDiscoveryOptions = {},
): Promise<UsageFileDiscoveryResult> {
  return await discoverUsageFiles({
    agent: "claude_code",
    roots: claudeUsageRoots(options),
    ...(options.fileSystem ? { fileSystem: options.fileSystem } : {}),
    acceptsFile: (path) => path.endsWith(".jsonl"),
  });
}

export async function scanClaudeUsage(options: UsageScanOptions): Promise<UsageScanResult> {
  const discovery = await discoverClaudeUsageFiles(options);
  return await scanUsageFiles({
    agent: "claude_code",
    startAt: options.startAt,
    endAt: options.endAt,
    discovery,
    ...(options.signal ? { signal: options.signal } : {}),
    ...(options.fileSystem ? { fileSystem: options.fileSystem } : {}),
    createParser: () => new ClaudeUsageParser(),
  });
}

// This alias makes the local-only nature of discovered paths explicit to API consumers.
export type ClaudeUsageFile = LocalUsageFile;

class ClaudeUsageParser implements UsageLineParser {
  parse(
    value: Record<string, unknown>,
    _cursor: UsageSourceCursor,
  ): {
    event?: NormalizedUsageEvent;
    reason?: "unknown_record" | "invalid_timestamp" | "invalid_model" | "invalid_usage";
  } {
    const message = record(value.message);
    const usageValue = message?.usage;
    if (!message || usageValue === undefined) {
      return value.type === undefined ? { reason: "unknown_record" } : {};
    }
    if ((value.type !== undefined && value.type !== "assistant") || message?.role === "user") {
      return { reason: "unknown_record" };
    }
    const usage = record(usageValue);
    if (!usage) {
      return { reason: "invalid_usage" };
    }

    const occurredAt = canonicalInstant(value.timestamp);
    if (!occurredAt) {
      return { reason: "invalid_timestamp" };
    }
    const model = message.model === "<synthetic>" ? "synthetic" : boundedModel(message.model);
    if (!model) {
      return { reason: "invalid_model" };
    }

    const tokens = parseClaudeTokens(usage);
    const dimensions = parseDimensions(usage);
    const tools = parseBillableTools(usage.server_tool_use);
    const sourceCost = parseSourceCost(value.costUSD);
    if (!tokens || !dimensions || !tools || sourceCost.invalid) {
      return { reason: "invalid_usage" };
    }

    return {
      event: {
        occurred_at: occurredAt,
        agent: "claude_code",
        model,
        billing_channel: "anthropic_direct",
        channel_source: "agent_default",
        input_tokens: tokens.input,
        cache_read_tokens: tokens.cacheRead,
        cache_write_5m_tokens: tokens.cacheWrite5m,
        cache_write_1h_tokens: tokens.cacheWrite1h,
        cache_write_inferred_tokens: tokens.cacheWriteInferred,
        output_tokens: tokens.output,
        reasoning_tokens: tokens.reasoning,
        requests: 1,
        context_bucket: contextBucket(tokens.input),
        service_tier: dimensions.serviceTier,
        speed: dimensions.speed,
        inference_geo: dimensions.inferenceGeo,
        billable_tools: tools,
        ...(sourceCost.microusd !== undefined ? { source_cost_microusd: sourceCost.microusd } : {}),
        source_cost_covered_requests: sourceCost.microusd === undefined ? 0 : 1,
      },
    };
  }
}

function parseClaudeTokens(usage: Record<string, unknown>):
  | {
      input: number;
      cacheRead: number;
      cacheWrite5m: number;
      cacheWrite1h: number;
      cacheWriteInferred: number;
      output: number;
      reasoning: number;
    }
  | undefined {
  const uncachedInput = safeCount(usage.input_tokens);
  const output = safeCount(usage.output_tokens);
  const cacheRead = optionalCount(usage.cache_read_input_tokens);
  const cacheWriteTotal = optionalCount(usage.cache_creation_input_tokens);
  if (
    uncachedInput === undefined ||
    output === undefined ||
    cacheRead === undefined ||
    cacheWriteTotal === undefined
  ) {
    return undefined;
  }

  let cacheWrite5m = 0;
  let cacheWrite1h = 0;
  const cacheCreation = usage.cache_creation;
  if (cacheCreation !== undefined && cacheCreation !== null) {
    const breakdown = record(cacheCreation);
    if (!breakdown) {
      return undefined;
    }
    const fiveMinutes = optionalCount(breakdown.ephemeral_5m_input_tokens);
    const oneHour = optionalCount(breakdown.ephemeral_1h_input_tokens);
    if (fiveMinutes === undefined || oneHour === undefined) {
      return undefined;
    }
    cacheWrite5m = fiveMinutes;
    cacheWrite1h = oneHour;
  }

  const classifiedCacheWrite = safeSum(cacheWrite5m, cacheWrite1h);
  if (classifiedCacheWrite === undefined || classifiedCacheWrite > cacheWriteTotal) {
    return undefined;
  }
  const cacheWriteInferred = cacheWriteTotal - classifiedCacheWrite;
  const input = safeSum(uncachedInput, cacheRead, cacheWriteTotal);
  if (input === undefined) {
    return undefined;
  }

  let reasoning = 0;
  if (usage.output_tokens_details !== undefined && usage.output_tokens_details !== null) {
    const outputDetails = record(usage.output_tokens_details);
    const thinkingTokens = safeCount(outputDetails?.thinking_tokens);
    if (thinkingTokens === undefined || thinkingTokens > output) {
      return undefined;
    }
    reasoning = thinkingTokens;
  }
  if (safeSum(input, output) === undefined) {
    return undefined;
  }
  return {
    input,
    cacheRead,
    cacheWrite5m,
    cacheWrite1h,
    cacheWriteInferred,
    output,
    reasoning,
  };
}

function parseDimensions(
  usage: Record<string, unknown>,
): { serviceTier: string; speed: string; inferenceGeo: string } | undefined {
  const serviceTier = optionalDimension(usage.service_tier);
  const speed = optionalDimension(usage.speed);
  const inferenceGeo = optionalDimension(usage.inference_geo);
  return serviceTier !== undefined && speed !== undefined && inferenceGeo !== undefined
    ? { serviceTier, speed, inferenceGeo }
    : undefined;
}

function parseBillableTools(
  value: unknown,
): Partial<Record<"web_search" | "web_fetch", number>> | undefined {
  if (value === undefined || value === null) {
    return {};
  }
  const serverTools = record(value);
  if (!serverTools) {
    return undefined;
  }
  const webSearch = optionalCount(serverTools.web_search_requests);
  const webFetch = optionalCount(serverTools.web_fetch_requests);
  if (webSearch === undefined || webFetch === undefined) {
    return undefined;
  }
  return {
    ...(webSearch > 0 ? { web_search: webSearch } : {}),
    ...(webFetch > 0 ? { web_fetch: webFetch } : {}),
  };
}

function parseSourceCost(value: unknown): { microusd?: bigint; invalid: boolean } {
  if (value === undefined || value === null) {
    return { invalid: false };
  }
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0) {
    return { invalid: true };
  }
  const rounded = Math.round(value * 1_000_000);
  return Number.isSafeInteger(rounded)
    ? { microusd: BigInt(rounded), invalid: false }
    : { invalid: true };
}

function optionalCount(value: unknown): number | undefined {
  return value === undefined || value === null ? 0 : safeCount(value);
}

function optionalDimension(value: unknown): string | undefined {
  return value === undefined || value === null || value === ""
    ? "unknown"
    : boundedDimension(value);
}
