<script lang="ts">
import { formatCost, formatCount } from "$lib/format";
import {
  dailyMaximum,
  dailyTooltip,
  dailyValue,
  shareFraction,
  type UsageDailyRow,
} from "$lib/usage-metrics";

let {
  rows,
  id = "usage-daily",
}: {
  rows: UsageDailyRow[];
  id?: string;
} = $props();

let mode = $state<"tokens" | "cost">("tokens");
let tableOpen = $state(false);

const maximum = $derived(dailyMaximum(rows, mode));
const hasUsage = $derived(rows.some((row) => row.totals.total_tokens > 0));

/** A bar's height against the tallest day, as a percentage of the plot. */
function barPercent(row: UsageDailyRow): number {
  return shareFraction(dailyValue(row, mode), maximum) * 100;
}

/** One stacked segment's share of its own day, so the three add up to the bar. */
function segmentPercent(row: UsageDailyRow, value: number): number {
  return shareFraction(value, row.totals.total_tokens) * 100;
}

/** `Sep 4` — the axis is dense, so a day names its month only when the month changes. */
function axisLabel(row: UsageDailyRow, index: number): string | null {
  const month = row.date.slice(0, 7);
  if (index > 0 && rows[index - 1]?.date.slice(0, 7) === month) return row.date.slice(8);
  return `${monthName(row.date)} ${row.date.slice(8)}`;
}

function monthName(date: string): string {
  return new Intl.DateTimeFormat("en-US", { month: "short", timeZone: "UTC" }).format(
    new Date(`${date}T00:00:00Z`),
  );
}
</script>

<div class="usage-daily" {id}>
  <div class="usage-daily-controls">
    <div class="usage-daily-modes" role="group" aria-label="Daily bars measure">
      <button
        class="text-button"
        type="button"
        aria-pressed={mode === "tokens"}
        onclick={() => (mode = "tokens")}>Tokens</button
      >
      <button
        class="text-button"
        type="button"
        aria-pressed={mode === "cost"}
        onclick={() => (mode = "cost")}>Cost</button
      >
    </div>
    <span class="count-pill">UTC</span>
  </div>

  {#if !hasUsage}
    <p class="empty-state">No Usage on these days.</p>
  {:else}
    <div class="usage-daily-plot" role="img" aria-label="Usage by day">
      {#each rows as row, index (row.date)}
        <div class="usage-daily-column">
          <div class="usage-daily-bar" style:height="{barPercent(row)}%" title={dailyTooltip(row)}>
            {#if mode === "tokens"}
              <i
                class="usage-daily-segment segment-output"
                style:height="{segmentPercent(row, row.segments.output)}%"
              ></i>
              <i
                class="usage-daily-segment segment-fresh"
                style:height="{segmentPercent(row, row.segments.freshInput)}%"
              ></i>
              <i
                class="usage-daily-segment segment-cached"
                style:height="{segmentPercent(row, row.segments.cachedInput)}%"
              ></i>
            {/if}
          </div>
          <span class="usage-daily-axis">{axisLabel(row, index)}</span>
        </div>
      {/each}
    </div>
    {#if mode === "tokens"}
      <div class="usage-daily-legend" aria-hidden="true">
        <span><i class="usage-daily-key segment-cached"></i>Cached input</span>
        <span><i class="usage-daily-key segment-fresh"></i>Fresh input</span>
        <span><i class="usage-daily-key segment-output"></i>Output</span>
      </div>
    {/if}
  {/if}

  <button
    class="text-button usage-daily-toggle"
    type="button"
    aria-expanded={tableOpen}
    aria-controls="{id}-table"
    onclick={() => (tableOpen = !tableOpen)}
    >{tableOpen ? "Hide daily breakdown" : "Show daily breakdown"}</button
  >
  {#if tableOpen}
    <div class="table-wrap" id="{id}-table">
      <table class="usage-daily-table">
        <caption class="visually-hidden">Usage by UTC day</caption>
        <thead>
          <tr>
            <th scope="col">Date</th>
            <th scope="col">Total</th>
            <th scope="col">In</th>
            <th scope="col">Out</th>
            <th scope="col">Cached</th>
            <th scope="col">Reasoning</th>
            <th scope="col">Messages</th>
            <th scope="col">Cost</th>
          </tr>
        </thead>
        <tbody>
          {#each rows as row (row.date)}
            <tr>
              <th scope="row">{row.date}</th>
              <td>{formatCount(row.totals.total_tokens)}</td>
              <td>{formatCount(row.totals.input_tokens)}</td>
              <td>{formatCount(row.totals.output_tokens)}</td>
              <td>{formatCount(row.totals.cache_read_input_tokens)}</td>
              <td>{formatCount(row.totals.reasoning_tokens)}</td>
              <td>{formatCount(row.totals.messages)}</td>
              <td>{formatCost(row.cost)}</td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>
  {/if}
</div>
