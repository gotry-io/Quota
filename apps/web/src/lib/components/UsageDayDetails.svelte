<script lang="ts">
import type {
  AccountUsageSummaryV3 as AccountUsageSummary,
  UsageBreakdown,
} from "@gotry-io/quota-protocol";
import { formatActivityDate, usageDayCoverageLabel, usageDayNotices } from "$lib/usage-activity";
import { agentDisplayName, costCoverage, formatCost, formatCount } from "$lib/format";

let {
  date,
  loading,
  error,
  usage,
  onRetry,
  onClose,
}: {
  date: string;
  loading: boolean;
  error: string | null;
  usage: AccountUsageSummary | null;
  onRetry: () => void;
  onClose: () => void;
} = $props();

const notices = $derived(usage ? usageDayNotices(usage) : []);
const agents = $derived(usage ? usage.breakdowns.filter((item) => item.dimension === "agent") : []);
const models = $derived(usage ? usage.breakdowns.filter((item) => item.dimension === "model") : []);

function rowKey(item: UsageBreakdown): string {
  return `${item.dimension}:${item.key}`;
}
</script>

<article id="usage-day-details" class="usage-day-details">
  <div class="usage-day-heading">
    <div>
      <p class="eyebrow">Selected day</p>
      <h3>{formatActivityDate(date)}</h3>
    </div>
    <button class="text-button" type="button" onclick={onClose}>Close day details</button>
  </div>
  {#if loading}
    <p class="usage-day-status" role="status">Loading this day's Usage…</p>
  {:else if error}
    <div class="notice" role="alert">
      {error}
      <button class="text-button notice-action" type="button" onclick={onRetry}>Try again</button>
    </div>
  {:else if usage}
    <div class="usage-day-metrics">
      <div><span>Input</span><strong>{formatCount(usage.totals.input_tokens)}</strong></div>
      <div><span>Output</span><strong>{formatCount(usage.totals.output_tokens)}</strong></div>
      <div><span>Requests</span><strong>{formatCount(usage.totals.requests)}</strong></div>
      <div>
        <span>API-equivalent cost</span>
        <strong>{formatCost(usage.cost)}</strong>
        <small>{costCoverage(usage.cost)}</small>
      </div>
    </div>
    <p class="usage-day-coverage">
      Coverage · {usageDayCoverageLabel(usage.coverage, usage.coverage_truncated === true)}
    </p>
    {#each notices as notice (notice)}
      <p class="usage-day-note">{notice}</p>
    {/each}
    <div class="usage-day-splits">
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
          <tbody>
            {#if agents.length === 0}
              <tr><td colspan="4">No agent Usage for this day.</td></tr>
            {:else}
              {#each agents as item (rowKey(item))}
                <tr>
                  <th scope="row">{agentDisplayName(item.key)}</th>
                  <td>{formatCount(item.totals.input_tokens)}</td>
                  <td>{formatCount(item.totals.output_tokens)}</td>
                  <td>{formatCost(item.cost)}</td>
                </tr>
              {/each}
            {/if}
          </tbody>
        </table>
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
          <tbody>
            {#if models.length === 0}
              <tr><td colspan="4">No model Usage for this day.</td></tr>
            {:else}
              {#each models as item (rowKey(item))}
                <tr>
                  <th scope="row">{item.key}</th>
                  <td>{formatCount(item.totals.input_tokens)}</td>
                  <td>{formatCount(item.totals.output_tokens)}</td>
                  <td>{formatCost(item.cost)}</td>
                </tr>
              {/each}
            {/if}
          </tbody>
        </table>
      </div>
    </div>
  {/if}
</article>
