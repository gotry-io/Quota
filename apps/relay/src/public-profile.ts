import {
  type AccountUsageSummaryV3 as AccountUsageSummary,
  PROTOCOL_VERSION,
  type PublicProfile,
  PublicProfileSlugSchema,
} from "@gotry-io/quota-protocol";
import type { StoredQuotaSnapshot as RelaySnapshot } from "@gotry-io/relay-core";

export function normalizePublicSlug(value: string): string | null {
  const slug = value
    .trim()
    .toLowerCase()
    .replaceAll(/[^a-z0-9]+/g, "-")
    .replaceAll(/^-+|-+$/g, "")
    .slice(0, 39);
  const parsed = PublicProfileSlugSchema.safeParse(slug);
  return parsed.success ? parsed.data : null;
}

export function publicProfileFromAccount(input: {
  slug: string;
  displayLabel: string | null;
  snapshots: readonly RelaySnapshot[];
  usage: AccountUsageSummary;
}): PublicProfile {
  const quota = [];
  const seen = new Set<string>();
  for (const observation of input.snapshots) {
    const provider = observation.snapshot.provider;
    if (seen.has(provider)) continue;
    seen.add(provider);
    quota.push({
      provider,
      plan: observation.snapshot.account.plan ?? null,
      windows: observation.snapshot.windows.map((window) => ({
        title: window.title,
        used_percent: window.used_percent,
        ...(window.remaining_value !== undefined
          ? { remaining_value: window.remaining_value }
          : {}),
        ...(window.limit_value !== undefined ? { limit_value: window.limit_value } : {}),
        ...(window.value_unit !== undefined ? { value_unit: window.value_unit } : {}),
      })),
    });
  }
  const models = input.usage.breakdowns
    .filter((item) => item.dimension === "model")
    .map((item) => ({
      name: item.key,
      tokens: item.totals.input_tokens + item.totals.output_tokens,
    }))
    .sort((left, right) => right.tokens - left.tokens)
    .slice(0, 5);
  return {
    protocol_version: PROTOCOL_VERSION,
    username: input.slug,
    display_label: input.displayLabel,
    quota,
    usage: {
      range: input.usage.range,
      input_tokens: input.usage.totals.input_tokens,
      output_tokens: input.usage.totals.output_tokens,
      cost_status: input.usage.cost.status,
      amount_microusd: input.usage.cost.amount_microusd,
      models,
    },
  };
}

export type { PublicProfile };
