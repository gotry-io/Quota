<script lang="ts">
import type {
  AccountDeviceRead,
  AccountSummaryRead,
  UsageActivityDayRead,
  UsagePeriodRead,
} from "@gotry-io/quota-protocol";
import {
  agentDisplayName,
  inferenceProviderDisplayName,
  platformDisplayName,
  providerDisplayName,
} from "@gotry-io/quota-protocol";
import type { AccountSummaryDocumentResult } from "$lib/server/document-port";
import {
  accountActivityRange,
  beginWebLogin,
  browserTimezone,
  deleteAccount,
  deleteDevice,
  fetchAccountActivity,
  fetchAccountSummary,
} from "$lib/account-client";
import QuotaWindows from "$lib/components/QuotaWindows.svelte";
import UsageActivity from "$lib/components/UsageActivity.svelte";
import {
  costBasisLabel,
  formatCost,
  formatCount,
  lastReadingCopy,
  observationFreshnessCopy,
} from "$lib/format";
import { deviceActivity } from "$lib/device-activity";
import { observedSnapshotStatus } from "@gotry-io/quota-model";
import { DASHBOARD_PATH, planDisplayName } from "$lib/routes";
import type { PageProps } from "./$types";

let { data }: PageProps = $props();

const periodNames = [
  { key: "today", label: "Today" },
  { key: "last_7_days", label: "Last 7 days" },
  { key: "last_30_days", label: "Last 30 days" },
  { key: "all", label: "All time" },
] as const;

let summary = $state<AccountSummaryRead | null>(null);
let activityDays = $state<UsageActivityDayRead[] | null>(null);
let loadError = $state<string | null>(null);
let activityMessage = $state("Loading Usage activity…");
let selectedPeriod = $state<(typeof periodNames)[number]["key"]>("last_30_days");

const activityRange = accountActivityRange(new Date());
let period = $derived<UsagePeriodRead | null>(summary ? summary.usage[selectedPeriod] : null);
let deviceNames = $derived(
  new Map(summary?.devices.map((device) => [device.id, device.display_name]) ?? []),
);
/** Every model leaf of the selected period, flattened for one table. */
let modelRows = $derived(
  (period?.agents ?? []).flatMap((agent) =>
    agent.providers.flatMap((provider) =>
      provider.models.map((model) => ({
        key: `${agent.agent}/${provider.provider}/${model.model}`,
        agent: agent.agent,
        provider: provider.provider,
        ...model,
      })),
    ),
  ),
);

$effect(() => {
  const streamed = data.streamed.summary;
  // The document render has no clock, so it asks for UTC. A browser that keeps another calendar
  // asks again for its own, because a local day begins at local midnight and that is what decides
  // where `today` and the trailing windows start and end.
  if (streamed && browserTimezone() === "UTC") void streamed.then(applySummaryResult);
  else void loadSummary();
  void loadActivity();
});

async function loadSummary(): Promise<void> {
  applySummaryResult(await fetchAccountSummary());
}

async function loadActivity(): Promise<void> {
  const result = await fetchAccountActivity(activityRange);
  if (result.status === "ok") {
    activityDays = result.activity.days;
    return;
  }
  activityMessage = "Usage activity is unavailable.";
}

function applySummaryResult(result: AccountSummaryDocumentResult): void {
  if (result.status === "unauthorized") {
    window.location.replace("/");
    return;
  }
  if (result.status === "error") {
    loadError = "Quota could not load this account. Refresh to try again.";
    activityMessage = "Usage activity is unavailable.";
    return;
  }
  summary = result.summary;
  loadError = null;
}

async function onDeleteDevice(device: AccountDeviceRead, event: Event): Promise<void> {
  if (!window.confirm(`Delete ${device.display_name} and all of its Quota and Usage data?`)) {
    return;
  }
  const button = event.currentTarget;
  if (button instanceof HTMLButtonElement) button.disabled = true;
  const outcome = await deleteDevice(device.id);
  if (outcome === "reauth") {
    beginWebLogin(DASHBOARD_PATH);
    return;
  }
  if (outcome === "error") {
    if (button instanceof HTMLButtonElement) button.disabled = false;
    loadError = "Quota could not delete this device. Recent authentication may be required.";
    return;
  }
  await loadSummary();
}

async function onDeleteAccount(event: Event): Promise<void> {
  if (!window.confirm("Delete this Quota Account and all of its Device, quota, and Usage data?")) {
    return;
  }
  const button = event.currentTarget;
  if (button instanceof HTMLButtonElement) button.disabled = true;
  const outcome = await deleteAccount();
  if (outcome === "reauth") {
    beginWebLogin(DASHBOARD_PATH);
    return;
  }
  if (outcome === "error") {
    if (button instanceof HTMLButtonElement) button.disabled = false;
    loadError = "Quota could not delete this Account. Recent authentication may be required.";
    return;
  }
  window.location.assign("/");
}

function deviceName(deviceId: string): string {
  return deviceNames.get(deviceId) ?? "Device";
}

function otherReportingDevices(subscription: AccountSummaryRead["subscriptions"][number]): string {
  return subscription.sources
    .filter((source) => source.observed_at !== subscription.snapshot.observed_at)
    .map((source) => deviceName(source.device_id))
    .join(", ");
}

function reportingDevice(subscription: AccountSummaryRead["subscriptions"][number]): string {
  const selected = subscription.sources.find(
    (source) => source.observed_at === subscription.snapshot.observed_at,
  );
  return deviceName(selected?.device_id ?? "");
}
</script>

<section id="dashboard-view" class="dashboard" aria-labelledby="dashboard-title">
  <div class="dashboard-heading">
    <div>
      <p class="eyebrow">Account</p>
      <h1 id="dashboard-title">Quota</h1>
    </div>
  </div>
  {#if loadError}
    <div id="account-error" class="notice" role="alert">{loadError}</div>
  {/if}
  <section class="dashboard-section" aria-labelledby="quota-title">
    <div class="dashboard-section-heading">
      <div>
        <p class="eyebrow">Plan limits</p>
        <h2 id="quota-title">Subscriptions</h2>
      </div>
    </div>
    <div id="quota-list" class="quota-grid">
      {#if summary && summary.subscriptions.length === 0}
        <p class="empty-state">No quota snapshots yet. Sign in from QuotaBar to add this Mac.</p>
      {:else if summary}
        {#each summary.subscriptions as subscription (subscription.key)}
          {@const snapshot = subscription.snapshot}
          {@const quotaStatus = observedSnapshotStatus(snapshot)}
          {@const alsoReporting = otherReportingDevices(subscription)}
          <article class="quota-card">
            <div class="quota-card-heading">
              <div class="quota-card-identity">
                <p class="quota-card-provider">{providerDisplayName(subscription.provider)}</p>
                <p class="quota-card-account">
                  {[snapshot.account.label, planDisplayName(snapshot.account.plan)]
                    .filter(Boolean)
                    .join(" · ") || "Account"}
                </p>
              </div>
            </div>
            <QuotaWindows windows={snapshot.windows} provider={subscription.provider} />
            <p class="quota-card-meta">
              {reportingDevice(subscription)} · {observationFreshnessCopy(
                quotaStatus,
                snapshot.observed_at,
              )}
            </p>
            {#if alsoReporting}
              <p class="quota-card-meta">Also reporting: {alsoReporting}</p>
            {/if}
          </article>
        {/each}
      {/if}
    </div>
  </section>
  <section class="dashboard-section" aria-labelledby="usage-title">
    <div class="dashboard-section-heading">
      <div>
        <p class="eyebrow">Usage</p>
        <h2 id="usage-title">Totals</h2>
      </div>
      <div class="period-tabs" role="group" aria-label="Usage period">
        {#each periodNames as item (item.key)}
          <button
            class="text-button"
            type="button"
            aria-pressed={selectedPeriod === item.key}
            onclick={() => {
              selectedPeriod = item.key;
            }}>{item.label}</button
          >
        {/each}
      </div>
    </div>
    <div class="summary-grid">
      <article
        ><span>Tokens</span><strong id="token-total"
          >{period ? formatCount(period.totals.total_tokens) : "—"}</strong
        ><small id="token-split"
          >{period
            ? `${formatCount(period.totals.input_tokens)} in · ${formatCount(period.totals.output_tokens)} out`
            : ""}</small
        ></article
      >
      <article
        ><span>API-equivalent cost</span><strong id="cost-total"
          >{period ? formatCost(period.cost) : "—"}</strong
        >{#if period}<small id="cost-basis">{costBasisLabel(period.cost)}</small>{/if}</article
      >
    </div>
    {#if period?.partial}
      <p class="usage-day-note">Some hours in this period were scanned incompletely.</p>
    {/if}
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th scope="col">Agent</th>
            <th scope="col">Provider</th>
            <th scope="col">Model</th>
            <th scope="col">Input</th>
            <th scope="col">Output</th>
            <th scope="col">Cost</th>
          </tr>
        </thead>
        <tbody id="usage-breakdown">
          {#if period}
            {#if modelRows.length === 0}
              <tr><td colspan="6">No Usage has been synced for this period.</td></tr>
            {:else}
              {#each modelRows as row (row.key)}
                <tr>
                  <td>{agentDisplayName(row.agent)}</td>
                  <td>{inferenceProviderDisplayName(row.provider)}</td>
                  <td>{row.model}</td>
                  <td>{formatCount(row.totals.input_tokens)}</td>
                  <td>{formatCount(row.totals.output_tokens)}</td>
                  <td>{formatCost(row.cost)}</td>
                </tr>
              {/each}
            {/if}
          {/if}
        </tbody>
      </table>
    </div>
  </section>
  <section class="dashboard-section" aria-labelledby="usage-activity-title">
    <div class="dashboard-section-heading">
      <div>
        <p class="eyebrow">Usage</p>
        <h2 id="usage-activity-title">Activity</h2>
      </div>
      <span id="usage-activity-status" class="count-pill" aria-live="polite">
        {activityRange.from} – {activityRange.to}
      </span>
    </div>
    {#if activityDays}
      <UsageActivity days={activityDays} range={activityRange} />
    {:else}
      <div id="usage-activity-grid" class="usage-activity-state" aria-live="polite">
        {activityMessage}
      </div>
    {/if}
  </section>
  <section class="dashboard-section" aria-labelledby="devices-title">
    <div class="dashboard-section-heading">
      <div>
        <p class="eyebrow">Installations</p>
        <h2 id="devices-title">Devices</h2>
      </div>
      <span id="device-count" class="count-pill">{summary ? summary.devices.length : ""}</span>
    </div>
    <div id="device-list" class="device-grid">
      {#if summary && summary.devices.length === 0}
        <p class="empty-state">No devices yet. Sign in from QuotaBar to add this Mac.</p>
      {:else if summary}
        {#each summary.devices as device (device.id)}
          {@const activity = deviceActivity(device)}
          <article class="device-card">
            <div class="device-card-heading">
              <h3>{device.display_name}</h3>
              <span class="status-pill status-{activity.tone}">{activity.label}</span>
            </div>
            <p>
              {platformDisplayName(device.platform)} · {lastReadingCopy(activity.since)}
            </p>
            <button
              class="text-button danger-button"
              type="button"
              onclick={(event) => void onDeleteDevice(device, event)}
              >Delete device and data</button
            >
          </article>
        {/each}
      {/if}
    </div>
  </section>
  <section class="dashboard-section danger-zone" aria-labelledby="account-actions-title">
    <div>
      <p class="eyebrow">Danger zone</p>
      <h2 id="account-actions-title">Delete Account</h2>
      <p>Remove this Account, every Device, all Quota and Usage data, sessions, and deletion controls.</p>
    </div>
    <button
      id="delete-account"
      class="button button-danger"
      type="button"
      onclick={(event) => void onDeleteAccount(event)}>Delete Account and data</button
    >
  </section>
</section>
