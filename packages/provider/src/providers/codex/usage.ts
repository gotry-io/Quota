import { homedir } from "node:os";
import { basename, join } from "node:path";
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

interface TokenUsage {
  input: number;
  cacheRead: number;
  cacheWrite: number;
  output: number;
  reasoning: number;
  total: number;
}

export function codexUsageRoots(options: UsageDiscoveryOptions = {}): string[] {
  if (options.roots) {
    return [...options.roots];
  }
  const home = options.homeDirectory ?? homedir();
  const codexHome = options.environment?.CODEX_HOME?.trim() || join(home, ".codex");
  return [join(codexHome, "sessions"), join(codexHome, "archived_sessions")];
}

export async function discoverCodexUsageFiles(
  options: UsageDiscoveryOptions = {},
): Promise<UsageFileDiscoveryResult> {
  return await discoverUsageFiles({
    agent: "codex",
    roots: codexUsageRoots(options),
    ...(options.fileSystem ? { fileSystem: options.fileSystem } : {}),
    acceptsFile: (path) => {
      const name = basename(path);
      return name.startsWith("rollout-") && name.endsWith(".jsonl");
    },
  });
}

export async function scanCodexUsage(options: UsageScanOptions): Promise<UsageScanResult> {
  const discovery = await discoverCodexUsageFiles(options);
  return await scanUsageFiles({
    agent: "codex",
    startAt: options.startAt,
    endAt: options.endAt,
    discovery,
    ...(options.signal ? { signal: options.signal } : {}),
    ...(options.fileSystem ? { fileSystem: options.fileSystem } : {}),
    createParser: () => new CodexUsageParser(),
  });
}

// This alias makes the local-only nature of discovered paths explicit to API consumers.
export type CodexUsageFile = LocalUsageFile;

class CodexUsageParser implements UsageLineParser {
  private currentModel = "unknown";
  private serviceTier = "unknown";
  private speed = "unknown";
  private previousTotals: TokenUsage | undefined;

  parse(
    value: Record<string, unknown>,
    _cursor: UsageSourceCursor,
  ): {
    event?: NormalizedUsageEvent;
    reason?: "unknown_record" | "invalid_timestamp" | "invalid_model" | "invalid_usage";
  } {
    const type = value.type;
    if (type === "turn_context") {
      const payload = record(value.payload);
      const model = boundedModel(payload?.model);
      if (!model) {
        return { reason: "invalid_model" };
      }
      this.currentModel = model;
      return {};
    }
    if (type !== "event_msg") {
      return hasUsageShape(value) ? { reason: "unknown_record" } : {};
    }

    const payload = record(value.payload);
    if (!payload || typeof payload.type !== "string") {
      return { reason: "unknown_record" };
    }
    if (payload.type === "thread_settings_applied") {
      return this.applyThreadSettings(payload);
    }
    if (payload.type !== "token_count") {
      return {};
    }

    const occurredAt = canonicalInstant(value.timestamp);
    if (!occurredAt) {
      return { reason: "invalid_timestamp" };
    }
    const infoValue = payload.info;
    if (infoValue === null || infoValue === undefined) {
      return {};
    }
    const info = record(infoValue);
    if (!info) {
      return { reason: "invalid_usage" };
    }

    const parsedModel = modelFrom(payload, info);
    if (parsedModel.invalid) {
      return { reason: "invalid_model" };
    }
    if (parsedModel.model) {
      this.currentModel = parsedModel.model;
    }
    const totalResult = optionalTokenUsage(info.total_token_usage);
    const lastResult = optionalTokenUsage(info.last_token_usage);
    if (totalResult.invalid || lastResult.invalid) {
      return { reason: "invalid_usage" };
    }

    const totalUsage = totalResult.usage;
    const lastUsage = lastResult.usage;
    let usage: TokenUsage | undefined;
    if (totalUsage) {
      if (this.previousTotals && equalUsage(totalUsage, this.previousTotals)) {
        this.previousTotals = totalUsage;
        return {};
      }
      usage = lastUsage ?? subtractUsage(totalUsage, this.previousTotals);
      this.previousTotals = totalUsage;
      if (!usage) {
        return { reason: "invalid_usage" };
      }
    } else {
      usage = lastUsage;
    }
    if (!usage || isEmptyUsage(usage)) {
      return {};
    }

    return {
      event: {
        occurred_at: occurredAt,
        agent: "codex",
        model: this.currentModel,
        billing_channel: "openai_direct",
        channel_source: "agent_default",
        input_tokens: usage.input,
        cache_read_tokens: usage.cacheRead,
        cache_write_5m_tokens: 0,
        cache_write_1h_tokens: 0,
        cache_write_inferred_tokens: usage.cacheWrite,
        output_tokens: usage.output,
        reasoning_tokens: usage.reasoning,
        requests: 1,
        context_bucket: contextBucket(usage.input),
        service_tier: this.serviceTier,
        speed: this.speed,
        inference_geo: "unknown",
        billable_tools: {},
        source_cost_covered_requests: 0,
      },
    };
  }

  private applyThreadSettings(payload: Record<string, unknown>): { reason?: "invalid_usage" } {
    const settings = record(payload.thread_settings);
    if (!settings || settings.service_tier === undefined) {
      return {};
    }
    switch (settings.service_tier) {
      case "fast":
      case "priority":
        this.serviceTier = "priority";
        this.speed = "fast";
        return {};
      case "default":
      case "standard":
        this.serviceTier = "standard";
        this.speed = "standard";
        return {};
      case "flex":
        this.serviceTier = "flex";
        this.speed = "unknown";
        return {};
      default:
        this.serviceTier = "unknown";
        this.speed = "unknown";
        return { reason: "invalid_usage" };
    }
  }
}

function optionalTokenUsage(value: unknown): { usage?: TokenUsage; invalid: boolean } {
  if (value === undefined || value === null) {
    return { invalid: false };
  }
  const parsed = parseTokenUsage(value);
  return parsed ? { usage: parsed, invalid: false } : { invalid: true };
}

function parseTokenUsage(value: unknown): TokenUsage | undefined {
  const usage = record(value);
  if (!usage) {
    return undefined;
  }
  const input = safeCount(usage.input_tokens);
  const output = safeCount(usage.output_tokens);
  const cacheRead =
    usage.cached_input_tokens === undefined ? 0 : safeCount(usage.cached_input_tokens);
  const cacheWrite =
    usage.cache_write_input_tokens === undefined ? 0 : safeCount(usage.cache_write_input_tokens);
  const reasoning =
    usage.reasoning_output_tokens === undefined ? 0 : safeCount(usage.reasoning_output_tokens);
  if (
    input === undefined ||
    output === undefined ||
    cacheRead === undefined ||
    cacheWrite === undefined ||
    reasoning === undefined
  ) {
    return undefined;
  }
  const cacheTotal = safeSum(cacheRead, cacheWrite);
  const derivedTotal = safeSum(input, output);
  if (
    cacheTotal === undefined ||
    cacheTotal > input ||
    reasoning > output ||
    derivedTotal === undefined
  ) {
    return undefined;
  }
  // `total_tokens` is a context counter in current Codex logs, not a billing-token sum.
  return { input, cacheRead, cacheWrite, output, reasoning, total: derivedTotal };
}

function subtractUsage(
  current: TokenUsage,
  previous: TokenUsage | undefined,
): TokenUsage | undefined {
  if (!previous) {
    return current;
  }
  if (
    current.input < previous.input ||
    current.cacheRead < previous.cacheRead ||
    current.cacheWrite < previous.cacheWrite ||
    current.output < previous.output ||
    current.reasoning < previous.reasoning ||
    current.total < previous.total
  ) {
    return undefined;
  }
  const difference = {
    input: current.input - previous.input,
    cacheRead: current.cacheRead - previous.cacheRead,
    cacheWrite: current.cacheWrite - previous.cacheWrite,
    output: current.output - previous.output,
    reasoning: current.reasoning - previous.reasoning,
    total: current.total - previous.total,
  };
  const cacheTotal = safeSum(difference.cacheRead, difference.cacheWrite);
  return cacheTotal !== undefined &&
    cacheTotal <= difference.input &&
    difference.reasoning <= difference.output &&
    difference.total === difference.input + difference.output
    ? difference
    : undefined;
}

function equalUsage(left: TokenUsage, right: TokenUsage): boolean {
  return (
    left.input === right.input &&
    left.cacheRead === right.cacheRead &&
    left.cacheWrite === right.cacheWrite &&
    left.output === right.output &&
    left.reasoning === right.reasoning &&
    left.total === right.total
  );
}

function isEmptyUsage(usage: TokenUsage): boolean {
  return usage.input === 0 && usage.output === 0 && usage.cacheWrite === 0;
}

function modelFrom(
  payload: Record<string, unknown>,
  info: Record<string, unknown>,
): { model?: string; invalid: boolean } {
  const candidate = payload.model ?? payload.model_name ?? info.model ?? info.model_name;
  if (candidate === undefined) {
    return { invalid: false };
  }
  const model = boundedModel(candidate);
  return model ? { model, invalid: false } : { invalid: true };
}

function hasUsageShape(value: Record<string, unknown>): boolean {
  return value.usage !== undefined || record(value.payload)?.info !== undefined;
}
