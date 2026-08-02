import type { QuotaCollectionReport, QuotaCollectionResult } from "@gotry-io/quota-protocol";
import { remainingPercent } from "@gotry-io/quota-model";

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
    const message = result.message ?? result.outcome;
    return [`${title}: ${result.outcome} — ${message}`];
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
