<script lang="ts">
import { inferenceProviderDisplayName } from "@gotry-io/quota-protocol";
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

<section class="public-profile" aria-labelledby="public-profile-title">
  <header class="public-profile-heading">
    <div>
      <p class="eyebrow">Public Usage</p>
      <h1 id="public-profile-title">@{profile.handle}</h1>
      <p class="public-profile-meta">Published {published} · Coding-agent Usage only</p>
    </div>
    <ShareCardDialog {profile} />
  </header>

  {#each periods as entry (entry.id)}
    <section class="public-period" aria-labelledby="{entry.id}-title">
      <h2 id="{entry.id}-title">{entry.title}</h2>
      {#if !hasUsage(entry.period)}
        <p class="empty-state">No Usage in this period.</p>
      {:else}
        <div class="public-stats">
          <article>
            <span>Tokens</span>
            <strong id="{entry.id}-tokens">{formatCount(entry.period.totals.total_tokens)}</strong>
            <small
              >{formatCount(entry.period.totals.input_tokens)} in · {formatCount(
                entry.period.totals.output_tokens,
              )} out</small
            >
          </article>
          <article>
            <span>Messages</span>
            <strong id="{entry.id}-messages">{formatCount(entry.period.totals.messages)}</strong>
            <small>Requests to a coding agent</small>
          </article>
          {#if entry.period.cost}
            <article>
              <span>API-equivalent cost</span>
              <strong id="{entry.id}-cost">{formatCost(entry.period.cost)}</strong>
              <small
                >{entry.period.cost.status === "complete"
                  ? "Every row priced"
                  : entry.period.cost.status === "partial"
                    ? "Priced subset only"
                    : "Unpriced"}</small
              >
            </article>
          {/if}
        </div>

        <div class="public-shares">
          <div>
            <h3>By provider</h3>
            <ul class="public-share-list">
              {#each entry.period.providers as share (share.provider)}
                <li>
                  <span class="public-share-label"
                    >{inferenceProviderDisplayName(share.provider)}</span
                  >
                  <span class="public-share-bar" aria-hidden="true">
                    <i style="width: {Math.max(2, share.share_permille / 10)}%"></i>
                  </span>
                  <span class="public-share-value">{sharePercent(share.share_permille)}</span>
                </li>
              {/each}
            </ul>
          </div>
          {#if entry.period.models}
            <div>
              <h3>By model</h3>
              <ul class="public-share-list">
                {#each entry.period.models as share (`${share.provider}/${share.model}`)}
                  <li>
                    <span class="public-share-label">{usageModelDisplayName(share.model)}</span>
                    <span class="public-share-bar" aria-hidden="true">
                      <i style="width: {Math.max(2, share.share_permille / 10)}%"></i>
                    </span>
                    <span class="public-share-value">{sharePercent(share.share_permille)}</span>
                  </li>
                {/each}
              </ul>
            </div>
          {/if}
        </div>
      {/if}
    </section>
  {/each}

  <section class="public-period" aria-labelledby="public-activity-title">
    <h2 id="public-activity-title">Activity</h2>
    <p class="public-profile-meta">The last 365 UTC days, as relative intensity.</p>
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
  </section>

  <p class="public-profile-footnote">
    This page shows Usage totals only. Remaining quota, devices, providers signed in on them, and
    the account behind it stay private. <a href="/">What Quota is</a>.
  </p>
</section>
