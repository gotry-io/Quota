<script lang="ts">
import { accountNoticeActionLabel, accountNoticeRetry } from "$lib/account-errors";
import { activityRangeKey, getAccountStore } from "$lib/account-store.svelte.ts";
import LoadingBlock from "$lib/components/LoadingBlock.svelte";
import ModelRiver from "$lib/components/ModelRiver.svelte";
import PageHeader from "$lib/components/PageHeader.svelte";
import RetryNotice from "$lib/components/RetryNotice.svelte";
import SetupBlock from "$lib/components/SetupBlock.svelte";
import { formatCost, formatCount, resetCopy, usageModelDisplayName } from "$lib/format";
import { modelColors } from "$lib/model-colors";
import { riverArrival, riverData } from "$lib/model-river";
import { foldModelRows, namedModelCount } from "$lib/model-usage";
import { tightestWindow } from "$lib/quota-overview";
import { bestCacheDay, busiestDays, clock, recapRhythm } from "$lib/recap";
import { copyRecapCard, type RecapCard } from "$lib/recap-card";
import { shortDate } from "$lib/usage-insights";
import { cacheHitLabel } from "$lib/usage-metrics";
import { localDate, usagePeriodRange, usagePeriodTitle } from "$lib/usage-period";

/**
 * The last full week, Monday to Sunday, in five posters: volume, the model of the week, cache
 * efficiency, rhythm, and headroom now. Derived from the week's period read; private until a
 * poster is copied ([ADR 0064](../../../../../../docs/decisions/0064-analysis-surfaces-lead-with-model-usage.md)).
 */
const store = getAccountStore();
const week = { segment: "week", offset: 1 } as const;
const range = $derived(usagePeriodRange(week, store.now));
const before = $derived(usagePeriodRange({ segment: "week", offset: 2 }, store.now));
const dates = $derived(usagePeriodTitle(week, store.now));
const shape = { breakdown: true, series: "model" } as const;
const entry = $derived(range ? store.periodFor(range, shape) : undefined);
const read = $derived(entry?.data ?? null);
const previous = $derived(before ? store.periodFor(before)?.data : undefined);
const rhythm = $derived(range ? store.rhythm[activityRangeKey(range)]?.data : undefined);
const colors = $derived(modelColors(store.summary?.usage.all.agents ?? []));
const rows = $derived(read ? foldModelRows(read.agents ?? []) : []);
const total = $derived(read?.totals.total_tokens ?? 0);
const top = $derived(rows[0] ?? null);
const agents = $derived(new Set(rows.flatMap((row) => row.agents.map((sent) => sent.agent))).size);
const river = $derived(
  read?.model_series && range
    ? riverData(read.model_series, range, "tokens", localDate(store.now))
    : null,
);
const arrival = $derived(river ? riverArrival(river) : null);
const cacheDay = $derived(read?.model_series ? bestCacheDay(read.model_series) : null);
const hours = $derived(rhythm ? rhythm.hours_of_day.map((hour) => hour.total_tokens) : null);
const rhythmFacts = $derived(hours ? recapRhythm(hours) : null);
const hourMax = $derived(hours ? Math.max(1, ...hours) : 1);
const tightest = $derived(
  store.summary ? tightestWindow(store.summary.subscriptions, store.now) : null,
);
const noMac = $derived(store.summary !== null && store.summary.devices.length === 0);
let copied = $state<string | null>(null);

$effect(() => {
  if (range) void store.ensurePeriod(range, shape);
});
$effect(() => {
  if (before) void store.ensurePeriod(before);
});
$effect(() => {
  if (range) void store.ensureRhythm(range);
});

function change(): string | null {
  const earlier = previous?.totals.total_tokens ?? 0;
  if (earlier <= 0 || total <= 0) return null;
  const percent = Math.round((total / earlier - 1) * 100);
  if (percent === 0) return "About the same as the week before";
  return `${Math.abs(percent)}% ${percent > 0 ? "more" : "fewer"} than the week before`;
}

const posters = $derived.by(() => {
  if (!read || total <= 0) return [];
  const list: Array<{
    id: string;
    eyebrow: string;
    headline: string;
    mono?: boolean;
    sentence: string;
    footer: string | null;
  }> = [];
  const models = namedModelCount(rows);
  const volumeChange = change();
  list.push({
    id: "volume",
    eyebrow: "Volume",
    headline: `${formatCount(total)} tokens`,
    sentence: `${volumeChange ? `${volumeChange}, across` : "Across"} ${models} ${models === 1 ? "model" : "models"} and ${agents} ${agents === 1 ? "agent" : "agents"}.`,
    footer: busiestDays(
      read.days.map((day) => ({ date: day.date, tokens: day.totals.total_tokens })),
    ),
  });
  if (top) {
    const second = rows[1];
    list.push({
      id: "model",
      eyebrow: "Model of the week",
      headline: usageModelDisplayName(top.model),
      mono: true,
      sentence: `carried ${Math.round((top.totals.total_tokens / total) * 100)}% of your tokens.`,
      footer:
        arrival && arrival.model === top.model && river
          ? `It arrived on ${shortDate(river.dates[arrival.index] ?? "")}.`
          : second
            ? `Next was ${usageModelDisplayName(second.model)}, at ${Math.round((second.totals.total_tokens / total) * 100)}%.`
            : null,
    });
  }
  const hit = cacheHitLabel(read.totals);
  if (hit) {
    list.push({
      id: "efficiency",
      eyebrow: "Efficiency",
      headline: `${hit} from cache`,
      sentence:
        read.cache_saved.amount_microusd !== null && read.cache_saved.amount_microusd !== "0"
          ? `about ${formatCost(read.cache_saved)} under list price.`
          : "of your input came back from a cache.",
      footer: cacheDay
        ? `Best cache day: ${shortDate(cacheDay.date)}, at ${cacheDay.percent}%.`
        : null,
    });
  }
  if (rhythmFacts) {
    list.push({
      id: "rhythm",
      eyebrow: "Rhythm",
      headline: clock(rhythmFacts.peak),
      sentence: "was your busiest hour.",
      footer: rhythmFacts.quiet
        ? `Nothing ran between ${clock(rhythmFacts.quiet.from)} and ${clock(rhythmFacts.quiet.to)}.`
        : null,
    });
  }
  if (tightest) {
    const reset = tightest.window.resets_at
      ? resetCopy(tightest.window.resets_at, store.now)
      : null;
    list.push({
      id: "headroom",
      eyebrow: "Headroom now",
      headline: `${Math.round(tightest.remaining)}% left`,
      sentence: `on ${tightest.name}, your tightest window today.`,
      footer: reset ? `It ${reset.charAt(0).toLowerCase()}${reset.slice(1)}.` : null,
    });
  }
  return list;
});

async function copy(poster: (typeof posters)[number]): Promise<void> {
  const card: RecapCard = {
    eyebrow: poster.eyebrow,
    headline: poster.headline,
    sentence: poster.sentence,
    dates,
    mono: poster.mono === true,
  };
  copied = (await copyRecapCard(card))
    ? `${poster.eyebrow} copied as an image.`
    : "Couldn't copy the image.";
}
</script>

<svelte:head>
  <title>Recap · Quota</title>
  <meta name="robots" content="noindex, nofollow" />
</svelte:head>

<PageHeader>
  {#snippet eyebrow()}Recap · {dates}{/snippet}
  Your week, in five numbers. <b>Private</b> until you copy one.
</PageHeader>

{#if store.loadError}
  <RetryNotice
    message={store.loadError.message}
    actionLabel={accountNoticeActionLabel(store.loadError)}
    onRetry={accountNoticeRetry(store.loadError, () => void store.refresh())}
  />
{/if}
{#if entry?.status === "error" && entry.error}
  <RetryNotice
    message={entry.error.message}
    actionLabel={accountNoticeActionLabel(entry.error)}
    onRetry={accountNoticeRetry(entry.error, () =>
      range ? void store.ensurePeriod(range, { ...shape, maxAgeMs: 0 }) : undefined,
    )}
  />
{/if}

{#if noMac}
  <SetupBlock title="Connect your first Mac" />
{:else if !read}
  {#if entry?.status !== "error"}
    <LoadingBlock lines={6} label="Loading your week" />
  {/if}
{:else if total <= 0}
  <p class="empty-state recap-empty">No usage between {dates.replace(" – ", " and ")}.</p>
{:else}
  {#each posters as poster (poster.id)}
    <section class="poster" aria-labelledby="poster-{poster.id}">
      <span class="eyebrow">{poster.eyebrow}</span>
      <div class="poster-body">
        <h2 id="poster-{poster.id}">
          <span class:model={poster.mono}>{poster.headline}</span>
          <small>{poster.sentence}</small>
        </h2>
        {#if poster.id === "model" && river}
          <ModelRiver
            data={river}
            mode="share"
            height={150}
            labels={false}
            annotate={false}
            {colors}
            format={formatCount}
            label="Share of each day's tokens by model this week"
          />
        {/if}
        {#if poster.id === "rhythm" && hours}
          <div class="hours" aria-hidden="true">
            {#each hours as value, hour (hour)}
              <i class:peak={hour === rhythmFacts?.peak} style:height="{(value / hourMax) * 100}%"></i>
            {/each}
          </div>
        {/if}
        <div class="poster-row">
          <span>{poster.footer ?? ""}</span>
          <button class="pill" type="button" onclick={() => void copy(poster)}>Copy as image</button>
        </div>
      </div>
    </section>
  {/each}
{/if}
<p class="visually-hidden" role="status">{copied ?? ""}</p>

<p class="recap-foot">A recap covers Monday to Sunday. Nothing here ranks you against anyone.</p>

<style>
.poster {
  display: grid;
  grid-template-columns: 220px minmax(0, 1fr);
  gap: 16px 48px;
  padding: 40px 0 44px;
  border-top: 1px solid var(--hairline);
}

.poster .eyebrow {
  padding-top: 12px;
  color: var(--brand);
}

.poster-body {
  display: grid;
  gap: 16px;
  min-width: 0;
}

h2 {
  font-family: var(--rounded);
  font-size: clamp(40px, 7vw, 76px);
  font-weight: 500;
  letter-spacing: -0.02em;
  line-height: 1;
  overflow-wrap: anywhere;
}

h2 .model {
  font-family: var(--mono);
  font-size: 0.55em;
  letter-spacing: -0.01em;
}

h2 small {
  display: block;
  margin-top: 12px;
  color: var(--body);
  font-size: 0.3em;
  letter-spacing: 0;
  line-height: 1.35;
}

.poster-row {
  display: flex;
  flex-wrap: wrap;
  gap: 12px;
  align-items: center;
  justify-content: space-between;
  color: var(--body);
}

.hours {
  display: grid;
  grid-template-columns: repeat(24, minmax(0, 1fr));
  gap: 3px;
  align-items: end;
  height: 72px;
}

.hours i {
  min-height: 1px;
  border-radius: 2px 2px 0 0;
  background: var(--activity-2);
}

.hours i.peak {
  background: var(--brand);
}

.recap-empty {
  padding: 24px 0;
  border-top: 1px solid var(--hairline);
}

.recap-foot {
  padding: 16px 0 8px;
  border-top: 1px solid var(--hairline);
  color: var(--body);
  font-size: 12.5px;
}

@media (max-width: 960px) {
  .poster {
    grid-template-columns: minmax(0, 1fr);
  }

  .poster .eyebrow {
    padding-top: 0;
  }
}
</style>
