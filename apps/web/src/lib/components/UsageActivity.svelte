<script lang="ts">
import type { AccountSummary, UsageBreakdown } from "@gotry-io/quota-protocol";
import { activityLevel, formatCount, formatShortDate, safeAdd } from "$lib/format";

let {
  breakdowns,
  range,
}: { breakdowns: UsageBreakdown[]; range: AccountSummary["usage"]["range"] } = $props();

const totals = $derived.by(() => {
  const map = new Map<string, { requests: number; tokens: number }>();
  for (const breakdown of breakdowns) {
    if (breakdown.key < range.from || breakdown.key > range.to) continue;
    const current = map.get(breakdown.key) ?? { requests: 0, tokens: 0 };
    current.requests = safeAdd(current.requests, breakdown.totals.requests);
    current.tokens = safeAdd(
      current.tokens,
      breakdown.totals.input_tokens,
      breakdown.totals.output_tokens,
    );
    map.set(breakdown.key, current);
  }
  return map;
});

const days = $derived.by(() => {
  const first = new Date(`${range.from}T00:00:00Z`);
  first.setUTCDate(first.getUTCDate() - first.getUTCDay());
  const last = new Date(`${range.to}T00:00:00Z`);
  last.setUTCDate(last.getUTCDate() + (6 - last.getUTCDay()));
  const maxTokens = Math.max(...[...totals.values()].map((value) => value.tokens), 0);
  const today = new Date().toISOString().slice(0, 10);
  const items: Array<{
    date: string;
    outside: boolean;
    today: boolean;
    level: number;
    label: string;
  }> = [];
  for (const cursor = new Date(first); cursor <= last; cursor.setUTCDate(cursor.getUTCDate() + 1)) {
    const date = cursor.toISOString().slice(0, 10);
    const value = totals.get(date);
    const outside = date < range.from || date > range.to;
    items.push({
      date,
      outside,
      today: date === today,
      level: activityLevel(value?.tokens ?? 0, maxTokens),
      label: `${formatShortDate(date)}: ${formatCount(value?.requests ?? 0)} messages, ${formatCount(value?.tokens ?? 0)} tokens`,
    });
  }
  return items;
});
</script>

<div class="usage-activity-card">
  <ul class="usage-activity-grid" aria-label="Usage activity by day">
    {#each days as day (day.date)}
      <li
        class="usage-activity-cell activity-level-{day.level}"
        class:activity-today={day.today}
        class:activity-outside={day.outside}
        aria-hidden={day.outside ? "true" : undefined}
        aria-label={day.outside ? undefined : day.label}
        title={day.outside ? undefined : day.label}
      ></li>
    {/each}
  </ul>
  <div class="activity-legend" aria-hidden="true">
    <span>Less</span>
    <i class="usage-activity-cell activity-level-0"></i>
    <i class="usage-activity-cell activity-level-1"></i>
    <i class="usage-activity-cell activity-level-2"></i>
    <i class="usage-activity-cell activity-level-3"></i>
    <i class="usage-activity-cell activity-level-4"></i>
    <span>More</span>
  </div>
</div>
