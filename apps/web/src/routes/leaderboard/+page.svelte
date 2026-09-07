<script lang="ts">
import { formatCount } from "$lib/format";
import { leaderboardSummary } from "$lib/leaderboard";
import { LEADERBOARD_PATH, PUBLIC_PROFILE_ORIGIN, publicProfilePath } from "$lib/routes";
import type { PageProps } from "./$types";

let { data }: PageProps = $props();

const board = $derived(data.board);
const entries = $derived(board.entries);
const summary = $derived(leaderboardSummary(board));
const url = `${PUBLIC_PROFILE_ORIGIN}${LEADERBOARD_PATH}`;
const generated = $derived(
  new Intl.DateTimeFormat("en-US", { dateStyle: "long", timeZone: "UTC" }).format(
    new Date(board.generated_at),
  ),
);
</script>

<svelte:head>
  <title>Leaderboard · Quota</title>
  <meta name="description" content={summary} />
  <link rel="canonical" href={url} />
  <meta property="og:type" content="website" />
  <meta property="og:title" content="Leaderboard · Quota" />
  <meta property="og:description" content={summary} />
  <meta property="og:url" content={url} />
  <meta name="twitter:card" content="summary" />
  <meta name="twitter:title" content="Leaderboard · Quota" />
  <meta name="twitter:description" content={summary} />
</svelte:head>

<section class="public-profile" aria-labelledby="leaderboard-title">
  <header class="public-profile-heading">
    <div>
      <p class="eyebrow">Public Usage</p>
      <h1 id="leaderboard-title">Leaderboard</h1>
      <p class="public-profile-meta">
        Last 30 UTC days · Folded {generated} · Everyone here asked to be listed
      </p>
    </div>
  </header>

  {#if entries.length === 0}
    <p class="empty-state">Nobody is listed yet.</p>
  {:else}
    <div class="leaderboard-scroll">
      <table class="leaderboard">
        <caption class="visually-hidden">
          Coding-agent Usage over the last 30 UTC days, most tokens first
        </caption>
        <thead>
          <tr>
            <th scope="col" class="leaderboard-rank">#</th>
            <th scope="col">Handle</th>
            <th scope="col" class="leaderboard-number">Tokens</th>
            <th scope="col" class="leaderboard-number">Messages</th>
          </tr>
        </thead>
        <tbody>
          {#each entries as entry (entry.handle)}
            <tr class:leaderboard-you={entry.handle === data.viewerHandle}>
              <td class="leaderboard-rank">{entry.rank}</td>
              <td>
                <a href={publicProfilePath(entry.handle)}>@{entry.handle}</a>
                {#if entry.handle === data.viewerHandle}
                  <span class="leaderboard-you-badge">You</span>
                {/if}
              </td>
              <td class="leaderboard-number">{formatCount(entry.total_tokens)}</td>
              <td class="leaderboard-number">{formatCount(entry.messages)}</td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>
  {/if}

  <p class="public-profile-footnote">
    This board ranks token totals only. Remaining quota, cost, models, devices, and the accounts
    behind these handles stay private. Listing is off until it is switched on in
    <a href="/my/settings">Settings › Public profile</a>. <a href="/">What Quota is</a>.
  </p>
</section>
