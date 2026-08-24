import {
  MAXIMUM_PUBLIC_PROFILE_QUOTA,
  type AccountUsageSummary,
  PUBLIC_PROFILE_PROTOCOL_VERSION,
  type PublicProfile,
  PublicProfileSlugSchema,
} from "@gotry-io/quota-protocol";
import { mergeQuotaObservations } from "@gotry-io/quota-model";
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

/**
 * A shareable page publishes one row per subscription — the same unit the dashboard, the
 * Overview, and the widget show, so two accounts on one provider read as two rows rather
 * than one silently chosen for the viewer.
 *
 * The page carries no freshness of its own, so a reading it shows is read as current.
 * Resolving the reporting devices first, and publishing only a subscription that still
 * describes current quota, is what keeps that true: a device that stopped collecting can no
 * longer speak for the account, and a device that re-uploaded an old reading cannot outrank
 * a newer one.
 */
export function publicProfileFromAccount(input: {
  slug: string;
  displayLabel: string | null;
  snapshots: readonly RelaySnapshot[];
  usage: AccountUsageSummary;
  now: Date;
}): PublicProfile {
  const quota = [];
  for (const subscription of mergeQuotaObservations(input.snapshots, input.now)) {
    if (subscription.is_stale) continue;
    if (quota.length === MAXIMUM_PUBLIC_PROFILE_QUOTA) break;
    quota.push({
      provider: subscription.snapshot.provider,
      plan: subscription.snapshot.account.plan ?? null,
      windows: subscription.snapshot.windows.map((window) => ({
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
    protocol_version: PUBLIC_PROFILE_PROTOCOL_VERSION,
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
