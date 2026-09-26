<script lang="ts">
import { inferenceProviderDisplayName } from "@gotry-io/quota-protocol";
import PageHeader from "$lib/components/PageHeader.svelte";
import PageSection from "$lib/components/PageSection.svelte";
import ShareCardDialog from "$lib/components/ShareCardDialog.svelte";
import { formatCost, formatCount, usageModelDisplayName } from "$lib/format";
import {
  buildPublicActivityModel,
  hasUsage,
  publicProfileSummary,
  sharePercent,
} from "$lib/public-profile";
import { publicProfileUrl } from "$lib/routes";
import type { PageProps } from "./$types";

let { data }: PageProps = $props();

const profile = $derived(data.profile);
const summary = $derived(publicProfileSummary(profile));
const activity = $derived(
  buildPublicActivityModel(profile.activity, profile.generated_at.slice(0, 10)),
);
const recent = $derived(profile.last_30_days);
const topModel = $derived(recent.models?.[0]?.model ?? null);
const periods = $derived([
  { id: "last-30-days", title: "Last 30 days", period: profile.last_30_days },
  { id: "all-time", title: "All time", period: profile.all },
]);
const published = $derived(
  new Intl.DateTimeFormat("en-US", { dateStyle: "long", timeZone: "UTC" }).format(
    new Date(profile.published_at),
  ),
);
</script>

<svelte:head>
  <title>{profile.handle} · Quota</title>
  <meta name="description" content={summary} />
  <link rel="canonical" href={publicProfileUrl(profile.handle)} />
  <meta property="og:type" content="profile" />
  <meta property="og:title" content="{profile.handle} · Quota" />
  <meta property="og:description" content={summary} />
  <meta property="og:url" content={publicProfileUrl(profile.handle)} />
  <meta name="twitter:card" content="summary" />
  <meta name="twitter:title" content="{profile.handle} · Quota" />
  <meta name="twitter:description" content={summary} />
</svelte:head>

<PageHeader id="public-profile-title">
  {#snippet eyebrow()}quota.gotry.io/u/{profile.handle} · Coding-agent Usage only{/snippet}
  <b>@{profile.handle}</b> ran
  <b>{formatCount(recent.totals.total_tokens)} tokens</b> in the last 30 days{#if topModel}, mostly on
    <b>{usageModelDisplayName(topModel)}</b>{/if}.
  {#snippet controls()}<ShareCardDialog {profile} />{/snippet}
  {#snippet meta()}<span>Published {published}</span>{/snippet}
</PageHeader>

{#each periods as entry (entry.id)}
  <PageSection id="{entry.id}-title" title={entry.title}>
    {#if !hasUsage(entry.period)}
      <p class="empty-state">No Usage in this period.</p>
    {:else}
      <dl class="figures">
        <div>
          <dt>Tokens</dt>
          <dd id="{entry.id}-tokens">{formatCount(entry.period.totals.total_tokens)}</dd>
          <dd class="figures-note">
            {formatCount(entry.period.totals.input_tokens)} in · {formatCount(
              entry.period.totals.output_tokens,
            )} out
          </dd>
        </div>
        <div>
          <dt>Messages</dt>
          <dd id="{entry.id}-messages">{formatCount(entry.period.totals.messages)}</dd>
          <dd class="figures-note">Requests to a coding agent</dd>
        </div>
        {#if entry.period.cost}
          <div>
            <dt>API-equivalent cost</dt>
            <dd id="{entry.id}-cost">{formatCost(entry.period.cost)}</dd>
            <dd class="figures-note">
              {entry.period.cost.status === "complete"
                ? "Every row priced"
                : entry.period.cost.status === "partial"
                  ? "Priced subset only"
                  : "Unpriced"}
            </dd>
          </div>
        {/if}
      </dl>

      <div class="shares">
        <div>
          <h3>By provider</h3>
          <ul class="share-list">
            {#each entry.period.providers as share (share.provider)}
              <li>
                <span class="share-label">{inferenceProviderDisplayName(share.provider)}</span>
                <span class="share-bar" aria-hidden="true">
                  <i style="width: {Math.max(2, share.share_permille / 10)}%"></i>
                </span>
                <span class="share-value">{sharePercent(share.share_permille)}</span>
              </li>
            {/each}
          </ul>
        </div>
        {#if entry.period.models}
          <div>
            <h3>By model</h3>
            <ul class="share-list">
              {#each entry.period.models as share (`${share.provider}/${share.model}`)}
                <li>
                  <span class="share-label share-model">{usageModelDisplayName(share.model)}</span>
                  <span class="share-bar" aria-hidden="true">
                    <i style="width: {Math.max(2, share.share_permille / 10)}%"></i>
                  </span>
                  <span class="share-value">{sharePercent(share.share_permille)}</span>
                </li>
              {/each}
            </ul>
          </div>
        {/if}
      </div>
    {/if}
  </PageSection>
{/each}

<PageSection id="public-activity-title" title="Activity">
  {#snippet note()}The last 365 UTC days, as relative intensity{/snippet}
  <div class="public-activity-scroll">
    <div
      class="public-activity-weeks"
      role="img"
      aria-label="Usage activity over the last 365 days"
      style="grid-template-columns: repeat({activity.weeks}, var(--activity-cell))"
    >
      {#each activity.cells as cell (cell.date)}
        <span
          class="usage-activity-cell activity-level-{cell.level}"
          class:activity-outside={cell.outside}
        ></span>
      {/each}
    </div>
  </div>
  <div class="activity-legend" aria-hidden="true">
    <span>Less</span>
    <i class="usage-activity-cell activity-level-0"></i>
    <i class="usage-activity-cell activity-level-1"></i>
    <i class="usage-activity-cell activity-level-2"></i>
    <i class="usage-activity-cell activity-level-3"></i>
    <i class="usage-activity-cell activity-level-4"></i>
    <span>More</span>
  </div>
</PageSection>

<p class="footnote">
  This page shows Usage totals only and ranks no one. Remaining quota, devices, providers signed in
  on them, and the account behind it stay private. <a href="/">What Quota is</a>.
</p>

<style>
.shares {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 16px 48px;
}

.shares h3 {
  margin: 0 0 8px;
  color: var(--body);
  font-size: 12px;
  font-weight: 500;
}

.share-list {
  display: grid;
  margin: 0;
  padding: 0;
  list-style: none;
}

.share-list li {
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(60px, 1fr) 48px;
  gap: 12px;
  align-items: center;
  min-height: 36px;
  border-bottom: 1px solid var(--hairline);
  font-size: 13.5px;
}

.share-label {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.share-model {
  font-family: var(--mono);
  font-size: 12.5px;
  font-weight: 600;
}

.share-bar {
  height: 4px;
  overflow: hidden;
  border-radius: 9999px;
  background: var(--meter-track);
}

.share-bar i {
  display: block;
  height: 100%;
  border-radius: 9999px;
  background: var(--ink);
}

.share-value {
  color: var(--body);
  font-variant-numeric: tabular-nums;
  text-align: right;
}

@media (max-width: 768px) {
  .shares {
    grid-template-columns: minmax(0, 1fr);
  }
}
</style>
