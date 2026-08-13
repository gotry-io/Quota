import type { AccountSummary } from "@gotry-io/quota-protocol";

export interface ShareQuotaWindow {
  title: string;
  used_percent: number;
  remaining_value?: number;
  limit_value?: number;
  value_unit?: "usd" | "credits" | "count";
}

export interface ShareQuotaProvider {
  provider: string;
  plan?: string | null;
  windows: ShareQuotaWindow[];
}

export interface ShareUsageModel {
  name: string;
  tokens: number;
  cost_label: string;
}

export interface ShareExportInput {
  display_label: string;
  quota: ShareQuotaProvider[];
  usage: {
    range: { from: string; to: string };
    tokens: number;
    cost_label: string;
    models: ShareUsageModel[];
  };
}

export interface ShareExport {
  quota_text: string;
  usage_text: string;
  quota_svg: string;
  usage_svg: string;
}

const WEB_LOCALE = "en-US";

export function shareInputFromAccountSummary(summary: AccountSummary): ShareExportInput {
  const newestByProvider = new Map<string, ShareQuotaProvider>();
  for (const observation of summary.quota) {
    const provider = observation.snapshot.provider;
    if (newestByProvider.has(provider)) continue;
    newestByProvider.set(provider, {
      provider,
      plan: observation.snapshot.account.plan ?? null,
      windows: observation.snapshot.windows.map((window) => {
        const mapped: ShareQuotaWindow = {
          title: window.title,
          used_percent: window.used_percent,
        };
        if (window.remaining_value !== undefined) mapped.remaining_value = window.remaining_value;
        if (window.limit_value !== undefined) mapped.limit_value = window.limit_value;
        if (window.value_unit !== undefined) mapped.value_unit = window.value_unit;
        return mapped;
      }),
    });
  }
  const models = summary.usage.breakdowns
    .filter((item) => item.dimension === "model")
    .map((item) => ({
      name: item.key,
      tokens: item.totals.input_tokens + item.totals.output_tokens,
      cost_label: formatCost(item.cost),
    }))
    .sort((left, right) => right.tokens - left.tokens)
    .slice(0, 5);
  return {
    display_label: summary.account.display_label ?? "Quota account",
    quota: [...newestByProvider.values()],
    usage: {
      range: summary.usage.range,
      tokens: summary.usage.totals.input_tokens + summary.usage.totals.output_tokens,
      cost_label: formatCost(summary.usage.cost),
      models,
    },
  };
}

export function buildShareExport(input: ShareExportInput): ShareExport {
  const quotaLines = input.quota.flatMap((provider) => {
    const heading = provider.plan
      ? `${titleCase(provider.provider)} · ${provider.plan}`
      : titleCase(provider.provider);
    const windows = provider.windows.map(
      (window) => `  ${window.title}: ${formatRemaining(window)}`,
    );
    return [heading, ...windows];
  });
  const quota_text = [
    `${input.display_label} · remaining quota`,
    ...(quotaLines.length > 0 ? quotaLines : ["No quota windows"]),
    "via Quota",
  ].join("\n");

  const modelLines = input.usage.models.map(
    (model) => `  ${model.name}: ${formatCount(model.tokens)} · ${model.cost_label}`,
  );
  const usage_text = [
    `${input.display_label} · usage ${input.usage.range.from}–${input.usage.range.to}`,
    `Tokens ${formatCount(input.usage.tokens)} · ${input.usage.cost_label}`,
    ...modelLines,
    "via Quota",
  ].join("\n");

  return {
    quota_text,
    usage_text,
    quota_svg: shareCard({
      eyebrow: "Remaining quota",
      title: input.display_label,
      rows:
        input.quota.length === 0
          ? [{ label: "No quota windows", value: "—" }]
          : input.quota.flatMap((provider) =>
              provider.windows.map((window) => ({
                label: `${titleCase(provider.provider)} · ${window.title}`,
                value: formatRemaining(window),
              })),
            ),
    }),
    usage_svg: shareCard({
      eyebrow: `Usage ${input.usage.range.from} – ${input.usage.range.to}`,
      title: input.display_label,
      rows: [
        { label: "Tokens", value: formatCount(input.usage.tokens) },
        { label: "API-equivalent cost", value: input.usage.cost_label },
        ...input.usage.models.map((model) => ({
          label: model.name,
          value: `${formatCount(model.tokens)} · ${model.cost_label}`,
        })),
      ],
    }),
  };
}

export function downloadShareFile(filename: string, contents: string, type: string): void {
  const blob = new Blob([contents], { type });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  link.rel = "noopener";
  document.body.append(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
}

function shareCard(input: {
  eyebrow: string;
  title: string;
  rows: { label: string; value: string }[];
}): string {
  const rows = input.rows
    .slice(0, 8)
    .map((row, index) => {
      const y = 118 + index * 28;
      return `<text x="32" y="${y}" fill="#525252" font-size="14">${escapeXml(row.label)}</text>
<text x="928" y="${y}" text-anchor="end" fill="#000" font-size="14">${escapeXml(row.value)}</text>`;
    })
    .join("\n");
  return `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="960" height="${Math.max(220, 140 + input.rows.slice(0, 8).length * 28)}" viewBox="0 0 960 ${Math.max(220, 140 + input.rows.slice(0, 8).length * 28)}" role="img">
  <rect width="100%" height="100%" fill="#ffffff"/>
  <rect x="0" y="0" width="960" height="8" fill="#82ddb8"/>
  <text x="32" y="48" fill="#087456" font-size="13">${escapeXml(input.eyebrow)}</text>
  <text x="32" y="86" fill="#000000" font-size="32" font-weight="600">${escapeXml(input.title)}</text>
  ${rows}
  <text x="32" y="${Math.max(220, 140 + input.rows.slice(0, 8).length * 28) - 24}" fill="#a3a3a3" font-size="12">quota.gotry.io</text>
</svg>
`;
}

function formatRemaining(window: ShareQuotaWindow): string {
  const remaining = Math.max(0, Math.min(100, 100 - window.used_percent));
  const percent = `${new Intl.NumberFormat(WEB_LOCALE, { maximumFractionDigits: 0 }).format(remaining)}%`;
  if (window.remaining_value === undefined) return percent;
  const absolute =
    window.value_unit === "usd"
      ? new Intl.NumberFormat(WEB_LOCALE, {
          style: "currency",
          currency: "USD",
          maximumFractionDigits: 2,
        }).format(window.remaining_value)
      : String(window.remaining_value);
  if (window.limit_value === undefined) return absolute;
  return `${percent} · ${absolute}`;
}

function formatCount(value: number): string {
  return new Intl.NumberFormat(WEB_LOCALE, {
    notation: value >= 1000 ? "compact" : "standard",
    maximumFractionDigits: 1,
  }).format(value);
}

function formatCost(cost: AccountSummary["usage"]["cost"]): string {
  if (cost.status === "unavailable" || cost.amount_microusd === null) return "— unpriced";
  const dollars = Number(cost.amount_microusd) / 1_000_000;
  const formatted = new Intl.NumberFormat(WEB_LOCALE, {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: 2,
  }).format(dollars);
  return cost.status === "partial" ? `≥ ${formatted}` : formatted;
}

function titleCase(value: string): string {
  return value
    .split(/[_\s]+/)
    .filter(Boolean)
    .map((part) => `${part[0]?.toUpperCase() ?? ""}${part.slice(1)}`)
    .join(" ");
}

function escapeXml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}
