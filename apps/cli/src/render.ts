import { remainingPercent } from "@gotry-io/quota-model";
import type {
  ProviderId,
  QuotaCollectionReport,
  QuotaCollectionResult,
  QuotaWindow,
} from "@gotry-io/quota-protocol";
import { PROVIDER_CATALOG } from "@gotry-io/quota-provider";

export function renderJson(report: QuotaCollectionReport, pretty: boolean): string {
  return `${JSON.stringify(report, null, pretty ? 2 : undefined)}\n`;
}

export function renderText(report: QuotaCollectionReport): string {
  const lines: string[] = [];
  for (const result of report.results) {
    lines.push(...renderResultText(result));
  }
  if (lines.length === 0) {
    lines.push("No providers requested.");
  }
  return `${lines.join("\n")}\n`;
}

function renderResultText(result: QuotaCollectionResult): string[] {
  const title = providerTitle(result.provider);
  if (result.outcome !== "success") {
    return [renderFailureLine(title, result)];
  }

  const lines: string[] = [];
  for (const snapshot of result.snapshots) {
    const plan = snapshot.account.plan ? ` (${snapshot.account.plan})` : "";
    const label = snapshot.account.label ? ` ${snapshot.account.label}` : "";
    lines.push(`${title}${plan}${label}`);
    if (snapshot.windows.length === 0) {
      lines.push("  no windows");
      continue;
    }
    for (const window of snapshot.windows) {
      lines.push(`  ${window.title}: ${formatWindowLine(window)}`);
    }
    lines.push(`  source: ${snapshot.source}`);
  }
  return lines;
}

function formatWindowLine(window: QuotaWindow): string {
  const remaining = remainingPercent(window.used_percent);
  const percentPart = `${formatPercent(remaining)}% remaining (${formatPercent(window.used_percent)}% used)`;
  const absolute = formatAbsolute(window);
  const reset = window.resets_at ? ` resets ${window.resets_at}` : "";
  return absolute ? `${percentPart}; ${absolute}${reset}` : `${percentPart}${reset}`;
}

function formatAbsolute(window: QuotaWindow): string | undefined {
  if (window.remaining_value === undefined || !window.value_unit) {
    return undefined;
  }
  const unit = window.value_unit === "usd" ? "$" : "";
  const suffix = window.value_unit === "usd" ? "" : ` ${window.value_unit}`;
  const remaining = `${unit}${formatQuantity(window.remaining_value)}${suffix}`;
  if (window.limit_value !== undefined) {
    const limit = `${unit}${formatQuantity(window.limit_value)}${suffix}`;
    return `${remaining} / ${limit}`;
  }
  return remaining;
}

function renderFailureLine(title: string, result: QuotaCollectionResult): string {
  if (result.outcome === "auth_required") {
    return `${title}: sign-in required — run \`${loginCommand(result.provider, result.message)}\``;
  }
  const label =
    result.outcome === "unavailable"
      ? "unavailable"
      : result.outcome === "unsupported"
        ? "unsupported"
        : "error";
  return `${title}: ${label} — ${conciseFailureDetail(result.message) ?? label}`;
}

function loginCommand(provider: ProviderId, message: string | undefined): string {
  const catalog = PROVIDER_CATALOG[provider].loginCommand;
  const fromMessage = message?.match(/`([^`]+)`/)?.[1]?.trim();
  if (!fromMessage) {
    return catalog;
  }
  // Prefer the backticked command when it looks like a real shell command.
  if (fromMessage.includes(" ") || fromMessage === catalog) {
    return fromMessage;
  }
  return catalog;
}

function conciseFailureDetail(message: string | undefined): string | undefined {
  const trimmed = message?.trim();
  if (!trimmed) {
    return undefined;
  }
  if (trimmed.includes("`")) {
    const withoutCommand = trimmed
      .replace(/`[^`]+`/g, "")
      .replace(/\s+/g, " ")
      .trim();
    if (
      !withoutCommand ||
      withoutCommand === "." ||
      withoutCommand.toLowerCase().startsWith("run")
    ) {
      return undefined;
    }
  }
  if (trimmed.length <= 96) {
    return trimmed;
  }
  const period = trimmed.indexOf(".");
  if (period >= 11 && period <= 95) {
    return trimmed.slice(0, period + 1);
  }
  return `${trimmed.slice(0, 93).trimEnd()}…`;
}

function providerTitle(provider: string): string {
  if (provider in PROVIDER_CATALOG) {
    return PROVIDER_CATALOG[provider as ProviderId].displayName;
  }
  return provider;
}

function formatPercent(value: number): string {
  if (Number.isInteger(value)) {
    return String(value);
  }
  return value.toFixed(1);
}

function formatQuantity(value: number): string {
  if (Number.isInteger(value)) {
    return String(value);
  }
  return value.toFixed(2);
}
