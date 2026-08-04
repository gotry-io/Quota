import { remainingPercent } from "@gotry-io/quota-model";
import type {
  ProviderId,
  QuotaCollectionReport,
  QuotaCollectionResult,
} from "@gotry-io/quota-protocol";

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
      const remaining = remainingPercent(window.used_percent);
      const reset = window.resets_at ? ` resets ${window.resets_at}` : "";
      lines.push(
        `  ${window.title}: ${formatPercent(remaining)}% remaining (${formatPercent(window.used_percent)}% used)${reset}`,
      );
    }
    lines.push(`  source: ${snapshot.source}`);
  }
  return lines;
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
  const fromMessage = message?.match(/`([^`]+)`/)?.[1]?.trim();
  if (fromMessage) {
    return normalizeLoginCommand(fromMessage, provider);
  }
  return defaultLoginCommand(provider);
}

function defaultLoginCommand(provider: ProviderId): string {
  switch (provider) {
    case "codex":
      return "codex login";
    case "claude":
      return "claude auth login";
    case "grok":
      return "grok login";
  }
}

function normalizeLoginCommand(command: string, provider: ProviderId): string {
  switch (command) {
    case "codex":
    case "codex login":
      return "codex login";
    case "claude":
    case "claude login":
    case "claude auth login":
      return "claude auth login";
    case "grok":
    case "grok login":
      return "grok login";
    default:
      return command.includes(" ") ? command : defaultLoginCommand(provider);
  }
}

function conciseFailureDetail(message: string | undefined): string | undefined {
  const trimmed = message?.trim();
  if (!trimmed) {
    return undefined;
  }
  // Auth failures already collapse to the login command above.
  if (trimmed.includes("`")) {
    const withoutCommand = trimmed.replace(/`[^`]+`/g, "").replace(/\s+/g, " ").trim();
    if (!withoutCommand || withoutCommand === "." || withoutCommand.toLowerCase().startsWith("run")) {
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
  switch (provider) {
    case "codex":
      return "Codex";
    case "claude":
      return "Claude Code";
    case "grok":
      return "Grok";
    default:
      return provider;
  }
}

function formatPercent(value: number): string {
  if (Number.isInteger(value)) {
    return String(value);
  }
  return value.toFixed(1);
}
