import { stripVTControlCharacters } from "node:util";
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

export function renderText(
  report: QuotaCollectionReport,
  options: { color?: boolean } = {},
): string {
  const style = textStyle(options.color === true);
  const lines: string[] = [];
  for (const result of report.results) {
    if (lines.length > 0) {
      lines.push("");
    }
    lines.push(...renderResultText(result, style));
  }
  if (lines.length === 0) {
    lines.push(style.warning("No configured providers found."));
    lines.push("Run `quotacli doctor` for setup details or use `--provider all`.");
  }
  return `${lines.join("\n")}\n`;
}

type TextStyle = ReturnType<typeof textStyle>;

function renderResultText(result: QuotaCollectionResult, style: TextStyle): string[] {
  const title = PROVIDER_CATALOG[result.provider].displayName;
  if (result.outcome !== "success") {
    return renderFailureLines(title, result, style);
  }

  const lines = [cardHeader(title, style)];
  for (const [index, snapshot] of result.snapshots.entries()) {
    if (index > 0) {
      lines.push(style.rule(`├${"┄".repeat(52)}`));
    }
    const identity = [snapshot.account.label, snapshot.account.plan]
      .filter((value): value is string => value !== undefined)
      .map(safeText)
      .filter(Boolean)
      .join(" · ");
    if (identity) {
      lines.push(cardLine(style.strong(identity), style));
    }
    if (snapshot.windows.length === 0) {
      lines.push(cardLine(style.dim("No quota limits reported."), style));
    } else {
      for (const window of snapshot.windows) {
        lines.push(...formatWindowLines(window, style).map((line) => cardLine(line, style)));
      }
    }
    lines.push(cardLine(style.dim(`Source · ${safeText(snapshot.source)}`), style));
  }
  if (result.message !== undefined) {
    lines.push(cardLine(style.warning("▲ Partial result · one or more sessions failed"), style));
  }
  lines.push(cardFooter(style));
  return lines;
}

function formatWindowLines(window: QuotaWindow, style: TextStyle): string[] {
  const absolute = formatAbsolute(window);
  const reset = window.resets_at ? `Resets ${window.resets_at}` : undefined;
  // Balance-only: an absolute remainder without a budget limit — do not invent a percent.
  const balanceOnly = window.remaining_value !== undefined && window.limit_value === undefined;
  if (balanceOnly && absolute) {
    return [
      style.strong(safeText(window.title)),
      `  ${absolute} remaining`,
      ...(reset ? [`  ${style.dim(reset)}`] : []),
    ];
  }
  const remaining = remainingPercent(window.used_percent);
  const summary = [
    `${formatPercent(remaining)}% left`,
    absolute,
    `${formatPercent(window.used_percent)}% used`,
  ]
    .filter(Boolean)
    .join(" · ");
  return [
    style.strong(safeText(window.title)),
    `  ${style.meter(quotaMeter(remaining), remaining)}  ${summary}`,
    ...(reset ? [`  ${style.dim(reset)}`] : []),
  ];
}

function formatAbsolute(window: QuotaWindow): string | undefined {
  if (window.remaining_value === undefined) {
    return undefined;
  }
  const remaining = window.value_unit
    ? formatValue(window.remaining_value, window.value_unit)
    : formatQuantity(window.remaining_value);
  if (window.limit_value !== undefined) {
    const limit = window.value_unit
      ? formatValue(window.limit_value, window.value_unit)
      : formatQuantity(window.limit_value);
    return `${remaining} / ${limit}`;
  }
  return remaining;
}

function formatValue(value: number, unit: NonNullable<QuotaWindow["value_unit"]>): string {
  return unit === "usd" ? `$${formatQuantity(value)}` : `${formatQuantity(value)} ${unit}`;
}

function renderFailureLines(
  title: string,
  result: QuotaCollectionResult,
  style: TextStyle,
): string[] {
  const outcome = result.outcome;
  if (outcome === "auth_required") {
    return [
      cardHeader(title, style),
      cardLine(style.warning("● Sign-in required"), style),
      cardLine(`Run \`${loginCommand(result.provider)}\``, style),
      cardFooter(style),
    ];
  }
  const label =
    outcome === "unavailable" ? "unavailable" : outcome === "unsupported" ? "unsupported" : "error";
  const failure =
    outcome === "unavailable" || outcome === "unsupported" || outcome === "error"
      ? outcome
      : "error";
  return [
    cardHeader(title, style),
    cardLine(`${style.error(`● ${label}`)} · ${fixedFailureDetail(failure)}`, style),
    cardFooter(style),
  ];
}

function cardHeader(title: string, style: TextStyle): string {
  const tail = "─".repeat(Math.max(2, 49 - title.length));
  return `${style.rule("┌─")} ${style.heading(title)} ${style.rule(tail)}`;
}

function cardLine(value: string, style: TextStyle): string {
  return `${style.rule("│")}  ${value}`;
}

function cardFooter(style: TextStyle): string {
  return style.rule(`└${"─".repeat(52)}`);
}

const CONTROL_CHARACTER_PATTERN = /[\u0000-\u001F\u007F-\u009F]/g;

function safeText(value: string): string {
  return stripVTControlCharacters(value)
    .replace(CONTROL_CHARACTER_PATTERN, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function quotaMeter(remaining: number, width = 18): string {
  const filled = Math.round((Math.min(Math.max(remaining, 0), 100) / 100) * width);
  return `${"█".repeat(filled)}${"░".repeat(width - filled)}`;
}

function textStyle(color: boolean) {
  const wrap = (code: number, value: string) =>
    color ? `\u001B[${code}m${value}\u001B[0m` : value;
  return {
    heading: (value: string) => wrap(1, value),
    strong: (value: string) => wrap(1, value),
    dim: (value: string) => wrap(2, value),
    rule: (value: string) => wrap(2, value),
    warning: (value: string) => wrap(33, value),
    error: (value: string) => wrap(31, value),
    meter: (value: string, remaining: number) =>
      wrap(remaining >= 50 ? 32 : remaining >= 20 ? 33 : 31, value),
  };
}

function loginCommand(provider: ProviderId): string {
  return PROVIDER_CATALOG[provider].loginCommand;
}

function fixedFailureDetail(outcome: Exclude<QuotaCollectionResult["outcome"], "success">): string {
  switch (outcome) {
    case "unavailable":
      return "provider temporarily unavailable";
    case "unsupported":
      return "operation not supported";
    case "error":
      return "invalid quota data";
    case "auth_required":
      return "authentication required";
  }
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
