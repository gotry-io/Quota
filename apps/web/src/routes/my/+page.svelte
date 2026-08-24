<script lang="ts">
import type {
  AccountDeviceWithHealth as AccountDevice,
  AccountQuotaObservationV3 as AccountQuotaObservation,
  AccountSummaryV3DeviceHealth as AccountSummary,
  AccountUsageSummaryV3 as AccountUsageSummary,
  UsageBreakdown,
} from "@gotry-io/quota-protocol";
import type { AccountSummaryDocumentResult } from "$lib/server/document-port";
import {
  beginWebLogin,
  deleteAccount,
  deleteDevice,
  fetchAccountSummary,
  fetchAccountUsageDay,
} from "$lib/account-client";
import QuotaWindows from "$lib/components/QuotaWindows.svelte";
import UsageActivity from "$lib/components/UsageActivity.svelte";
import UsageDayDetails from "$lib/components/UsageDayDetails.svelte";
import {
  agentDisplayName,
  costCoverage,
  formatCost,
  formatCount,
  formatDate,
  observedSnapshotStatusLabel,
  titleCase,
} from "$lib/format";
import { deviceHealthStatus } from "$lib/device-health";
import { observedSnapshotStatus } from "@gotry-io/quota-model";
import { DASHBOARD_PATH, planDisplayName } from "$lib/routes";
import { usageDateBreakdowns } from "$lib/usage-activity";
import type { PageProps } from "./$types";

let { data }: PageProps = $props();

let summary = $state<AccountSummary | null>(null);
let loadError = $state<string | null>(null);
let activityMessage = $state("Loading Usage activity…");
let selectedDate = $state<string | null>(null);
let dayLoading = $state(false);
let dayError = $state<string | null>(null);
let dayUsage = $state<AccountUsageSummary | null>(null);
let dayRequest = 0;
let dayAbort: AbortController | null = null;

$effect(() => {
  const streamed = data.streamed.summary;
  if (streamed) void streamed.then(applySummaryResult);
  else void loadSummary();
});

async function loadSummary(): Promise<void> {
  applySummaryResult(await fetchAccountSummary());
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

async function onDeleteDevice(device: AccountDevice, event: Event): Promise<void> {
  if (!window.confirm(`Delete ${device.display_name} and all of its Quota and Usage data?`)) {
    return;
  }
  const button = event.currentTarget;
  if (button instanceof HTMLButtonElement) button.disabled = true;
  const outcome = await deleteDevice(device.device_id);
  if (outcome === "reauth") {
    void beginWebLogin(DASHBOARD_PATH);
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
    void beginWebLogin(DASHBOARD_PATH);
    return;
  }
  if (outcome === "error") {
    if (button instanceof HTMLButtonElement) button.disabled = false;
    loadError = "Quota could not delete this Account. Recent authentication may be required.";
    return;
  }
  window.location.assign("/");
}

function deviceName(
  observation: AccountQuotaObservation,
  devices: AccountDevice[],
): string | undefined {
  return devices.find((device) => device.device_id === observation.device_id)?.display_name;
}

function agentBreakdowns(items: UsageBreakdown[]): UsageBreakdown[] {
  return items.filter((item) => item.dimension === "agent");
}

function modelBreakdowns(items: UsageBreakdown[]): UsageBreakdown[] {
  return items.filter((item) => item.dimension === "model");
}

function closeDayDetails(): void {
  dayAbort?.abort();
  dayAbort = null;
  dayRequest += 1;
  selectedDate = null;
  dayLoading = false;
  dayError = null;
  dayUsage = null;
}

async function selectDay(date: string): Promise<void> {
  if (selectedDate === date) {
    closeDayDetails();
    return;
  }
  await loadDay(date);
}

async function loadDay(date: string): Promise<void> {
  selectedDate = date;
  dayUsage = null;
  dayError = null;
  dayLoading = true;
  dayAbort?.abort();
  const controller = new AbortController();
  dayAbort = controller;
  const requestId = ++dayRequest;
  const result = await fetchAccountUsageDay(date, { signal: controller.signal });
  if (requestId !== dayRequest) return;
  if (result.status === "aborted") return;
  if (result.status === "unauthorized") {
    void beginWebLogin(DASHBOARD_PATH);
    return;
  }
  if (result.status === "error") {
    dayLoading = false;
    dayError = "Quota could not load this day's Usage. Try again.";
    return;
  }
  dayLoading = false;
  dayUsage = result.usage;
}
</script>

<section id="dashboard-view" class="dashboard" aria-labelledby="dashboard-title">
  <div class="dashboard-heading">
    <div>
      <p class="eyebrow">Account</p>
      <h1 id="dashboard-title">Usage</h1>
    </div>
  </div>
  {#if loadError}
    <div id="account-error" class="notice" role="alert">{loadError}</div>
  {/if}
  <div class="summary-grid">
    <article
      ><span>Input tokens</span><strong id="input-total"
        >{summary ? formatCount(summary.usage.totals.input_tokens) : "—"}</strong
      ></article
    >
    <article
      ><span>Output tokens</span><strong id="output-total"
        >{summary ? formatCount(summary.usage.totals.output_tokens) : "—"}</strong
      ></article
    >
    <article
      ><span>API-equivalent cost</span><strong id="cost-total"
        >{summary ? formatCost(summary.usage.cost) : "—"}</strong
      >{#if summary}<small id="cost-coverage">{costCoverage(summary.usage.cost)}</small>{/if}</article
    >
  </div>
  <section class="dashboard-section" aria-labelledby="quota-title">
    <div class="dashboard-section-heading">
      <div>
        <p class="eyebrow">Plan limits</p>
        <h2 id="quota-title">Quota</h2>
      </div>
    </div>
    <div id="quota-list" class="quota-grid">
      {#if summary && summary.quota.length === 0}
        <p class="empty-state">No quota snapshots yet. Sign in from QuotaBar to add this Mac.</p>
      {:else if summary}
        {#each summary.quota as observation (observation.device_id + observation.snapshot.provider)}
          {@const quotaStatus = observedSnapshotStatus(observation.snapshot)}
          <article class="quota-card">
            <div class="quota-card-heading">
              <div class="quota-card-identity">
                <p class="quota-card-provider">{titleCase(observation.snapshot.provider)}</p>
                <p class="quota-card-account">
                  {[observation.snapshot.account.label, planDisplayName(observation.snapshot.account.plan)]
                    .filter(Boolean)
                    .join(" · ") || "Account"}
                </p>
              </div>
              <span class="status-pill status-{quotaStatus}"
                >{observedSnapshotStatusLabel(quotaStatus)}</span
              >
            </div>
            <QuotaWindows
              windows={observation.snapshot.windows}
              provider={observation.snapshot.provider}
            />
            <p class="quota-card-meta">
              {deviceName(observation, summary.devices) ?? "Device"} · {formatDate(
                observation.snapshot.observed_at,
              )}
            </p>
          </article>
        {/each}
      {/if}
    </div>
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
        {#each summary.devices as device (device.device_id)}
          {@const healthStatus = deviceHealthStatus(device)}
          <article class="device-card">
            <div class="device-card-heading">
              <h3>{device.display_name}</h3>
              <span class="status-pill status-{healthStatus.tone}">{healthStatus.label}</span>
            </div>
            <p>
              {titleCase(device.platform)}
              {#if device.health}
                · {device.health.client_product === "quotabar" ? "QuotaBar" : "QuotaCLI"}
                {device.health.client_version} · report {formatDate(device.health.received_at)}
              {:else if device.last_seen_at}
                · last seen {formatDate(device.last_seen_at)}
              {:else}
                · never reported
              {/if}
            </p>
            {#if device.health}
              <p>
                Refresh {device.health.last_completed_refresh_at
                  ? formatDate(device.health.last_completed_refresh_at)
                  : "not reported"} · Account sync {device.health.last_successful_account_sync_at
                  ? formatDate(device.health.last_successful_account_sync_at)
                  : "not reported"}
              </p>
              {#if healthStatus.needsDeviceReview}
                <p>Review Diagnostics on this device.</p>
              {/if}
            {/if}
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
  <section class="dashboard-section" aria-labelledby="breakdown-title">
    <div class="dashboard-section-heading">
      <div>
        <p class="eyebrow">Usage</p>
        <h2 id="breakdown-title">By agent</h2>
      </div>
    </div>
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th scope="col">Agent</th>
            <th scope="col">Input</th>
            <th scope="col">Output</th>
            <th scope="col">Cost</th>
          </tr>
        </thead>
        <tbody id="usage-breakdown">
          {#if summary}
            {@const rows = agentBreakdowns(summary.usage.breakdowns)}
            {#if rows.length === 0}
              <tr><td colspan="4">No Usage has been synced for this range.</td></tr>
            {:else}
              {#each rows as item (item.key)}
                <tr>
                  <td>{agentDisplayName(item.key)}</td>
                  <td>{formatCount(item.totals.input_tokens)}</td>
                  <td>{formatCount(item.totals.output_tokens)}</td>
                  <td>{formatCost(item.cost)}</td>
                </tr>
              {/each}
            {/if}
          {/if}
        </tbody>
      </table>
    </div>
  </section>
  <section class="dashboard-section" aria-labelledby="model-breakdown-title">
    <div class="dashboard-section-heading">
      <div>
        <p class="eyebrow">Usage</p>
        <h2 id="model-breakdown-title">By model</h2>
      </div>
    </div>
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th scope="col">Model</th>
            <th scope="col">Input</th>
            <th scope="col">Output</th>
            <th scope="col">Cost</th>
          </tr>
        </thead>
        <tbody id="model-breakdown">
          {#if summary}
            {@const rows = modelBreakdowns(summary.usage.breakdowns)}
            {#if rows.length === 0}
              <tr><td colspan="4">No model Usage has been synced for this range.</td></tr>
            {:else}
              {#each rows as item (item.key)}
                <tr>
                  <td>{item.key}</td>
                  <td>{formatCount(item.totals.input_tokens)}</td>
                  <td>{formatCount(item.totals.output_tokens)}</td>
                  <td>{formatCost(item.cost)}</td>
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
        {summary ? `${summary.usage.range.from} – ${summary.usage.range.to}` : ""}
      </span>
    </div>
    {#if summary}
      <UsageActivity
        breakdowns={usageDateBreakdowns(summary.usage.breakdowns)}
        range={summary.usage.range}
        {selectedDate}
        onSelectDate={(date) => void selectDay(date)}
      />
      {#if selectedDate}
        {@const day = selectedDate}
        <UsageDayDetails
          date={day}
          loading={dayLoading}
          error={dayError}
          usage={dayUsage}
          onRetry={() => void loadDay(day)}
          onClose={closeDayDetails}
        />
      {/if}
    {:else}
      <div id="usage-activity-grid" class="usage-activity-state" aria-live="polite">
        {activityMessage}
      </div>
    {/if}
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
