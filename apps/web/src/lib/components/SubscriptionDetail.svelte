<script lang="ts">
import {
  expiryLines,
  formatWindowTitle,
  observedSnapshotStatus,
  quotaPace,
  remainingPercent,
  showsPercentMeter,
} from "@gotry-io/quota-model";
import {
  type AccountSummaryRead,
  providerDisplayName,
  type QuotaHistoryResponseRead,
} from "@gotry-io/quota-protocol";
import {
  type AccountError,
  accountNoticeActionLabel,
  accountNoticeRetry,
} from "$lib/account-errors";
import { meterTone } from "$lib/account-overview";
import LoadingBlock from "$lib/components/LoadingBlock.svelte";
import PaceLine from "$lib/components/PaceLine.svelte";
import PageHeader from "$lib/components/PageHeader.svelte";
import PageSection from "$lib/components/PageSection.svelte";
import QuotaMeter from "$lib/components/QuotaMeter.svelte";
import RetryNotice from "$lib/components/RetryNotice.svelte";
import {
  formatQuotaRemaining,
  NO_RESET_TIME_COPY,
  observationFreshnessCopy,
  observedSnapshotStatusLabel,
  paceDetail,
  paceHeadline,
  relativeAge,
  resetCopy,
  showsNoResetTime,
  usageModelDisplayName,
} from "$lib/format";
import { type ModelColors, modelColor } from "$lib/model-colors";
import { evenPaceRemaining, type WindowShare } from "$lib/quota-overview";
import { planDisplayName, QUOTA_PATH } from "$lib/routes";

type Subscription = AccountSummaryRead["subscriptions"][number];
type Source = Subscription["sources"][number];
type Snapshot = Subscription["snapshot"];
type QuotaWindow = Snapshot["windows"][number];

/**
 * One subscription: its windows with meters, pace lines and pace copy, an estimate of what used
 * its tightest day-or-longer window, and the readings behind it. No device id or account
 * identifier is printed.
 */
let {
  sel,
  summary,
  loadError,
  subscriptionSelectors,
  onRetry,
  now = new Date(),
  history = null,
  attribution = null,
  colors = new Map(),
  providerStatus = null,
}: {
  sel: string;
  summary: AccountSummaryRead | null;
  loadError: AccountError | null;
  subscriptionSelectors: Record<string, string>;
  onRetry: () => void;
  now?: Date;
  /** The Account's quota history for this subscription, when the history switch is on. */
  history?: QuotaHistoryResponseRead | null;
  /** What used the window named, estimated from Usage since it opened. */
  attribution?: { title: string; shares: readonly WindowShare[] | null } | null;
  colors?: ModelColors;
  providerStatus?: { indicator: string; description: string } | null;
} = $props();

const subscription = $derived(
  summary?.subscriptions.find((item) => subscriptionSelectors[item.key] === sel),
);
const title = $derived(
  subscription ? `${providerDisplayName(subscription.provider)} · Quota` : "Account · Quota",
);
const deviceNames = $derived(
  new Map(summary?.devices.map((device) => [device.id, device.display_name]) ?? []),
);
const sources = $derived(
  subscription
    ? [...subscription.sources].sort(
        (left, right) => Date.parse(right.observed_at) - Date.parse(left.observed_at),
      )
    : [],
);

function deviceName(deviceId: string): string {
  return deviceNames.get(deviceId) ?? "Device";
}

function sourceSnapshot(item: Subscription, source: Source): Snapshot | undefined {
  if (source.snapshot) return source.snapshot;
  if (source.observed_at === item.snapshot.observed_at) return item.snapshot;
  return undefined;
}

function primaryRemaining(snapshot: Snapshot | undefined, provider: string): string | undefined {
  const window = snapshot?.windows.find((item) => item.primary_cadence) ?? snapshot?.windows[0];
  return window ? formatQuotaRemaining(window, provider) : undefined;
}

function sourceFreshness(snapshot: Snapshot | undefined, observedAt: string): string {
  const status = snapshot ? observedSnapshotStatus(snapshot, now) : "available";
  return observationFreshnessCopy(status, observedAt, now);
}

function tone(window: QuotaWindow): string {
  return showsPercentMeter(window) ? meterTone(remainingPercent(window.used_percent)) : "none";
}

/** This cycle's Account samples for one window, oldest first. */
function samples(window: QuotaWindow): Array<{ at: number; used: number }> {
  const points = history?.sync ? history.windows[window.id]?.points : undefined;
  if (!points || !window.resets_at) return [];
  const reset = Date.parse(window.resets_at);
  return points
    .filter((point) => Math.abs(Date.parse(point.resets_at) - reset) < 3_600_000)
    .map((point) => ({ at: Date.parse(point.bucket_start), used: point.used_percent }))
    .sort((left, right) => left.at - right.at);
}

function paceLine(window: QuotaWindow) {
  const pace = quotaPace(window, now);
  if (pace.kind === "none" || !window.resets_at || !window.duration_seconds) return null;
  const points = samples(window);
  if (points.length === 0) return null;
  const end = Date.parse(window.resets_at);
  return {
    points,
    start: end - window.duration_seconds * 1_000,
    end,
    projected: pace.projected_at_reset,
    color:
      pace.kind === "runs_out"
        ? "var(--quota-warning)"
        : `var(--quota-${{ good: "healthy", warn: "warning", critical: "critical" }[meterTone(remainingPercent(window.used_percent))]})`,
  };
}
</script>

<svelte:head>
  <title>{title}</title>
  <meta name="robots" content="noindex, nofollow" />
</svelte:head>

{#if !subscription}
  <PageHeader id="subscription-title">
    {#snippet eyebrow()}<a href={QUOTA_PATH}>Quota</a>{/snippet}
    Subscription
    {#snippet controls()}<a class="pill" href={QUOTA_PATH}>← Quota</a>{/snippet}
  </PageHeader>
  {#if loadError}
    <RetryNotice
      message={loadError.message}
      actionLabel={accountNoticeActionLabel(loadError)}
      onRetry={accountNoticeRetry(loadError, onRetry)}
    />
  {/if}
  {#if !summary}
    {#if !loadError}
      <LoadingBlock lines={4} label="Loading subscription" />
    {/if}
  {:else}
    <p class="empty-state">This subscription is no longer reported.</p>
  {/if}
{:else}
  {@const snapshot = subscription.snapshot}
  {@const quotaStatus = observedSnapshotStatus(snapshot, now)}
  {@const current = quotaStatus === "available"}
  {@const plan = planDisplayName(snapshot.account.plan)}
  {@const name = providerDisplayName(subscription.provider)}
  {@const lines = snapshot.windows.map((window) => ({ window, pace: current ? paceLine(window) : null }))}
  {@const expiring = snapshot.windows.filter((window) => (window.expiries?.length ?? 0) > 0)}
  <PageHeader id="subscription-title">
    {#snippet eyebrow()}<a href={QUOTA_PATH}>Quota</a> <span>/</span> <span>{name}</span>{/snippet}
    <b>{name}</b>{#if plan}{" "}· {plan}{/if}
    {#snippet controls()}<a class="pill" href={QUOTA_PATH}>← Quota</a>{/snippet}
    {#snippet meta()}
      {#if snapshot.account.label}
        <span>{snapshot.account.label}</span>
      {/if}
      <span class="subscription-freshness" class:risk={!current}
        >{observationFreshnessCopy(quotaStatus, snapshot.observed_at, now)}</span
      >
    {/snippet}
  </PageHeader>
  {#if loadError}
    <RetryNotice
      message={loadError.message}
      actionLabel={accountNoticeActionLabel(loadError)}
      onRetry={accountNoticeRetry(loadError, onRetry)}
    />
  {/if}
  {#if !current}
    <div class="notice" role="status">
      <p>
        <b>{observedSnapshotStatusLabel(quotaStatus)}.</b> These are the last numbers a Mac read.
        Open QuotaBar there to bring {name} back; the website never asks for provider credentials.
      </p>
    </div>
  {/if}
  <div class="detail">
    <div class="main">
      <PageSection id="subscription-windows-title" title="Windows">
        <div class="windows">
          {#each lines as line (line.window.id)}
            {@const window = line.window}
            {@const pace = current ? quotaPace(window, now) : null}
            {@const headline = pace ? paceHeadline(pace, window.resets_at) : null}
            {@const detail = headline && pace ? paceDetail(pace) : null}
            {@const reset = current && window.resets_at ? resetCopy(window.resets_at, now) : null}
            <div class="wline">
              <span class="wname">{formatWindowTitle(window.title, window)}</span>
              <span class="wvalue tone-{current ? tone(window) : 'none'}"
                >{formatQuotaRemaining(window, subscription.provider)}</span
              >
              {#if current && showsPercentMeter(window)}
                <div class="full">
                  <QuotaMeter
                    remaining={remainingPercent(window.used_percent)}
                    tick={evenPaceRemaining(window, now)}
                    thick
                  />
                  {#if line.pace}
                    <PaceLine {...line.pace} now={now.getTime()} used={window.used_percent} />
                  {/if}
                </div>
              {/if}
              <div class="wfoot">
                <span
                  >{#if !current}Not current{:else if reset}{reset}{:else if !window.resets_at && showsNoResetTime(window)}{NO_RESET_TIME_COPY}{/if}</span
                >
                <span class="wpace">
                  {#if headline}
                    <span class:risk={pace?.kind === "runs_out"}>{headline}</span>
                  {/if}
                  {#if detail}<span>{detail}</span>{/if}
                </span>
              </div>
            </div>
          {/each}
        </div>
        {#if lines.some((line) => line.pace)}
          <div class="legend" aria-hidden="true">
            <span><i class="key-used"></i>Used so far</span>
            <span><i class="key-dashed"></i>At this pace until reset</span>
            <span><i class="key-tick"></i>Even pace</span>
          </div>
        {/if}
      </PageSection>

      {#if attribution && current}
        <PageSection id="window-usage-title" title="What used this window">
          {#snippet note()}{attribution.title} · estimated from Usage since it opened{/snippet}
          {#if attribution.shares === null}
            <LoadingBlock lines={2} label="Estimating the window" />
          {:else if attribution.shares.length === 0}
            <p class="empty-state">No Usage from this provider's agents since the window opened.</p>
          {:else}
            <div
              class="split"
              role="img"
              aria-label={attribution.shares
                .map((item) => `${item.row.model} ${Math.round(item.share * 100)}%`)
                .join(", ")}
            >
              {#each attribution.shares as item (item.row.key)}
                <i
                  style:flex-grow={item.share}
                  style:background={modelColor(colors, item.row.provider, item.row.model)}
                ></i>
              {/each}
            </div>
            <div class="legend">
              {#each attribution.shares.slice(0, 6) as item (item.row.key)}
                <span
                  ><i style:background={modelColor(colors, item.row.provider, item.row.model)}></i><span
                    class="model">{usageModelDisplayName(item.row.model)}</span
                  >&nbsp;{Math.round(item.share * 100)}%</span
                >
              {/each}
            </div>
          {/if}
        </PageSection>
      {/if}

      {#if expiring.length > 0 && current}
        <PageSection id="expiring-title" title="Expiring credits">
          {#each expiring as window (window.id)}
            <dl class="kv">
              {#each expiryLines(window.expiries ?? [], window.remaining_value, now) as line (line)}
                {@const [count, when] = line.split(" · ")}
                <dt>{count} {formatWindowTitle(window.title, window)}</dt>
                <dd>{when}</dd>
              {/each}
            </dl>
          {/each}
        </PageSection>
      {/if}
    </div>

    <div class="side">
      <PageSection id="subscription-sources-title" title="Readings">
        {#if sources.length === 0}
          <p class="empty-state">No devices reported this subscription.</p>
        {:else}
          <dl class="kv readings" aria-labelledby="subscription-sources-title">
            {#each sources as source (`${source.device_id}:${source.observed_at}`)}
              {@const reading = sourceSnapshot(subscription, source)}
              {@const remaining = primaryRemaining(reading, subscription.provider)}
              {@const reporting = source.observed_at === snapshot.observed_at}
              <dt>
                <span class="device">{deviceName(source.device_id)}</span>
                {#if reporting}<span class="tag good">Reporting</span>{/if}
                <span class="age">{sourceFreshness(reading, source.observed_at)}</span>
              </dt>
              <dd>{remaining ?? "—"}</dd>
            {/each}
          </dl>
        {/if}
      </PageSection>
      <PageSection id="subscription-source-title" title="Source">
        <dl class="kv">
          <dt>Read by</dt>
          <dd>QuotaBar</dd>
          <dt>Last reading</dt>
          <dd>{relativeAge(snapshot.observed_at, now)}</dd>
          {#if providerStatus}
            <dt>Provider status</dt>
            <dd>
              <span
                class="status"
                class:status-unavailable={providerStatus.indicator !== "none"}
                >{providerStatus.description}</span
              >
            </dd>
          {/if}
        </dl>
      </PageSection>
    </div>
  </div>
{/if}

<style>
.detail {
  display: grid;
  grid-template-columns: minmax(0, 1fr) 300px;
  gap: 0 48px;
  align-items: start;
}

.main,
.side {
  display: grid;
  min-width: 0;
}

.windows {
  display: grid;
}

.wline {
  display: grid;
  grid-template-columns: 1fr auto;
  gap: 2px 16px;
  padding: 14px 0;
  border-bottom: 1px solid var(--hairline);
}

.wline:first-child {
  padding-top: 0;
}

.wname {
  font-weight: 500;
}

.wvalue {
  font: 500 24px / 1.1 var(--rounded);
  font-variant-numeric: tabular-nums;
  text-align: right;
}

.full,
.wfoot {
  grid-column: 1 / -1;
}

.wfoot {
  display: flex;
  flex-wrap: wrap;
  gap: 12px;
  justify-content: space-between;
  color: var(--body);
  font-size: 12px;
}

.wpace {
  display: grid;
  text-align: right;
}

.tone-warn,
.risk {
  color: var(--quota-warning);
}

.tone-critical {
  color: var(--quota-critical);
}

.legend {
  display: flex;
  flex-wrap: wrap;
  gap: 6px 14px;
  align-items: center;
  color: var(--body);
  font-size: 12px;
}

.legend i {
  display: inline-block;
  width: 10px;
  height: 10px;
  margin-right: 6px;
  border-radius: 3px;
  vertical-align: -1px;
}

.legend i.key-used {
  height: 2px;
  border-radius: 0;
  background: var(--brand);
}

.legend i.key-dashed {
  height: 0;
  border-top: 2px dashed var(--body);
  border-radius: 0;
}

.legend i.key-tick {
  width: 2px;
  background: var(--ink);
  opacity: 0.45;
}

.split {
  display: flex;
  gap: 2px;
  height: 10px;
  overflow: hidden;
  border-radius: 9999px;
}

.split i {
  flex-basis: 0;
}

.model {
  font-family: var(--mono);
  font-size: 0.92em;
  color: var(--ink);
}

.kv {
  display: grid;
  grid-template-columns: 1fr auto;
  margin: 0;
}

.kv dt,
.kv dd {
  margin: 0;
  padding: 9px 0;
  border-bottom: 1px solid var(--hairline);
}

.kv dt {
  color: var(--body);
}

.kv dd {
  font-weight: 500;
  font-variant-numeric: tabular-nums;
  text-align: right;
}

.readings dt {
  display: flex;
  flex-wrap: wrap;
  gap: 2px 6px;
  align-items: center;
}

.device {
  color: var(--ink);
}

.age {
  flex-basis: 100%;
  font-size: 12px;
}

@media (max-width: 960px) {
  .detail {
    grid-template-columns: minmax(0, 1fr);
  }
}
</style>
