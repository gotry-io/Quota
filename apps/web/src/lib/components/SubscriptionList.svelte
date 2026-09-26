<script lang="ts">
import {
  formatWindowTitle,
  observedSnapshotStatus,
  quotaPace,
  remainingPercent,
  showsPercentMeter,
} from "@gotry-io/quota-model";
import { type AccountSummaryRead, providerDisplayName } from "@gotry-io/quota-protocol";
import { meterTone } from "$lib/account-overview";
import ProviderMark from "$lib/components/ProviderMark.svelte";
import QuotaMeter from "$lib/components/QuotaMeter.svelte";
import {
  formatQuotaRemaining,
  NO_RESET_TIME_COPY,
  observedSnapshotStatusLabel,
  paceHeadline,
  relativeAge,
  resetCopy,
  showsNoResetTime,
} from "$lib/format";
import { evenPaceRemaining } from "$lib/quota-overview";
import { planDisplayName, subscriptionPath } from "$lib/routes";

type Subscription = AccountSummaryRead["subscriptions"][number];
type QuotaWindow = Subscription["snapshot"]["windows"][number];

/**
 * Every subscription on the Quota page: as rows with up to three windows each, or as one table
 * row per window. A reading that is no longer current keeps its last numbers, dimmed, and names
 * why ([`docs/design.md`](../../../../../docs/design.md), principle 5).
 */
let {
  summary,
  selectors,
  now,
  layout = "list",
  providerStatus,
}: {
  summary: AccountSummaryRead;
  selectors: Record<string, string>;
  now: Date;
  layout?: "list" | "table";
  providerStatus: ReadonlyMap<string, { indicator: string; description: string }>;
} = $props();

const deviceNames = $derived(
  new Map(summary.devices.map((device) => [device.id, device.display_name])),
);

function reportingDevice(subscription: Subscription): string {
  const selected = subscription.sources.find(
    (source) => source.observed_at === subscription.snapshot.observed_at,
  );
  return deviceNames.get(selected?.device_id ?? "") ?? "Device";
}

function status(subscription: Subscription): string {
  return observedSnapshotStatus(subscription.snapshot, now);
}

function tone(window: QuotaWindow): string {
  return showsPercentMeter(window) ? meterTone(remainingPercent(window.used_percent)) : "none";
}

function resetLine(window: QuotaWindow): string {
  const reset = window.resets_at ? resetCopy(window.resets_at, now) : null;
  if (reset) return reset;
  if (!window.resets_at && showsNoResetTime(window)) return NO_RESET_TIME_COPY;
  return "";
}

function mayRunOut(window: QuotaWindow): boolean {
  return quotaPace(window, now).kind === "runs_out";
}

function dotClass(provider: string): string | null {
  const row = providerStatus.get(provider);
  if (!row) return null;
  if (row.indicator === "minor") return "minor";
  if (row.indicator === "major" || row.indicator === "critical") return "critical";
  return null;
}
</script>

{#snippet identity(subscription: Subscription)}
  {@const sel = selectors[subscription.key]}
  {@const dot = dotClass(subscription.provider)}
  {#if sel}
    <a class="name" href={subscriptionPath(sel)}>{providerDisplayName(subscription.provider)}</a>
  {:else}
    <span class="name">{providerDisplayName(subscription.provider)}</span>
  {/if}
  {#if dot}
    <span
      class="status-dot {dot}"
      title={providerStatus.get(subscription.provider)?.description}
      role="img"
      aria-label={providerStatus.get(subscription.provider)?.description}
    ></span>
  {/if}
{/snippet}

{#if layout === "list"}
  <ul class="subs">
    {#each summary.subscriptions as subscription (subscription.key)}
      {@const current = status(subscription) === "available"}
      {@const plan = planDisplayName(subscription.snapshot.account.plan)}
      <li class="sub" class:stale={!current}>
        <div class="who">
          <ProviderMark provider={subscription.provider} />
          <div class="who-text">
            <div class="who-name">{@render identity(subscription)}</div>
            <div class="who-meta">
              <span>{subscription.snapshot.account.label || "Account"}</span>
              {#if plan}<span class="tag">{plan}</span>{/if}
            </div>
          </div>
        </div>
        {#each [0, 1, 2] as slot (slot)}
          {@const window = subscription.snapshot.windows[slot]}
          {#if window}
            {@const title = formatWindowTitle(window.title, window)}
            <div class="win">
              <div class="win-title">{title}</div>
              <div class="win-value tone-{current ? tone(window) : 'none'}">
                {formatQuotaRemaining(window, subscription.provider)}
              </div>
              {#if current && showsPercentMeter(window)}
                <QuotaMeter
                  remaining={remainingPercent(window.used_percent)}
                  tick={evenPaceRemaining(window, now)}
                />
              {/if}
              {#if current}
                <div class="win-reset">
                  {resetLine(window)}{#if mayRunOut(window)}
                    {resetLine(window) ? " · " : ""}<span class="risk">may run out early</span>{/if}
                </div>
              {/if}
            </div>
          {:else}
            <div class="win" aria-hidden="true"></div>
          {/if}
        {/each}
        <div class="foot">
          {#if current}
            <b>{reportingDevice(subscription)}</b> · {relativeAge(subscription.snapshot.observed_at, now)}
          {:else}
            <span class="risk">{observedSnapshotStatusLabel(status(subscription))}</span><br />
            last reading {relativeAge(subscription.snapshot.observed_at, now)}
          {/if}
        </div>
      </li>
    {/each}
  </ul>
{:else}
  <div class="table-scroll">
    <table class="data-table">
      <caption class="visually-hidden">Every quota window</caption>
      <thead>
        <tr>
          <th scope="col">Subscription</th>
          <th scope="col">Plan</th>
          <th scope="col">Window</th>
          <th scope="col">Remaining</th>
          <th scope="col">Reset</th>
          <th scope="col">Pace</th>
          <th scope="col">Reporting</th>
        </tr>
      </thead>
      <tbody>
        {#each summary.subscriptions as subscription (subscription.key)}
          {@const current = status(subscription) === "available"}
          {#each subscription.snapshot.windows as window, index (window.id)}
            {@const headline = current ? paceHeadline(quotaPace(window, now), window.resets_at) : null}
            <tr>
              <th scope="row" class:quiet={index > 0}>
                {#if index === 0}{@render identity(subscription)}{:else}{providerDisplayName(subscription.provider)}{/if}
              </th>
              <td class="data-table-quiet">{planDisplayName(subscription.snapshot.account.plan) ?? ""}</td>
              <td>{formatWindowTitle(window.title, window)}</td>
              <td class="figure tone-{current ? tone(window) : 'none'}">
                {formatQuotaRemaining(window, subscription.provider)}
              </td>
              <td class="data-table-quiet">{current ? resetLine(window) || "—" : "—"}</td>
              <td>
                {#if headline}
                  <span class:risk={mayRunOut(window)} class:data-table-quiet={!mayRunOut(window)}
                    >{headline}</span
                  >
                {:else}
                  <span class="data-table-quiet">—</span>
                {/if}
              </td>
              <td class="data-table-quiet">
                {current
                  ? `${reportingDevice(subscription)} · ${relativeAge(subscription.snapshot.observed_at, now)}`
                  : observedSnapshotStatusLabel(status(subscription))}
              </td>
            </tr>
          {/each}
        {/each}
      </tbody>
    </table>
  </div>
{/if}

<style>
.subs {
  margin: 0;
  padding: 0;
  list-style: none;
}

.sub {
  display: grid;
  grid-template-columns: minmax(220px, 1.5fr) repeat(3, minmax(0, 1fr)) 140px;
  gap: 20px;
  align-items: center;
  padding: 14px 0;
  border-bottom: 1px solid var(--hairline);
}

.who {
  display: flex;
  gap: 12px;
  align-items: center;
  min-width: 0;
}

.who-text {
  min-width: 0;
}

.who-name {
  display: flex;
  gap: 6px;
  align-items: center;
}

.name {
  font-size: 15px;
  font-weight: 600;
  text-decoration: none;
}

a.name:hover {
  text-decoration: underline;
}

.who-meta {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  align-items: center;
  color: var(--body);
  font-size: 12px;
}

.status-dot {
  display: inline-block;
  width: 6px;
  height: 6px;
  border-radius: 9999px;
}

.status-dot.minor {
  background: var(--quota-warning);
}

.status-dot.critical {
  background: var(--quota-critical);
}

.win {
  min-width: 0;
  text-align: right;
}

.win-title,
.win-reset {
  color: var(--body);
  font-size: 11.5px;
}

.win-reset {
  margin-top: 4px;
}

.win-value {
  font-size: 15px;
  font-variant-numeric: tabular-nums;
  font-weight: 600;
}

.tone-warn,
.risk {
  color: var(--quota-warning);
}

.tone-critical {
  color: var(--quota-critical);
}

.sub.stale .win-value {
  color: var(--body);
}

.foot {
  color: var(--body);
  font-size: 12px;
  text-align: right;
}

.foot b {
  color: var(--ink);
  font-weight: 500;
}

.figure {
  font-variant-numeric: tabular-nums;
  font-weight: 600;
}

th.quiet {
  color: var(--body);
  font-weight: 400;
}

@media (max-width: 960px) {
  .sub {
    grid-template-columns: minmax(200px, 1.4fr) repeat(3, minmax(0, 1fr));
  }

  .foot {
    grid-column: 1 / -1;
    text-align: left;
  }
}

@media (max-width: 768px) {
  .sub {
    grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: 12px;
  }

  .who {
    grid-column: 1 / -1;
  }

  .win {
    text-align: left;
  }

  .win[aria-hidden="true"] {
    display: none;
  }
}
</style>
