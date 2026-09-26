<script lang="ts">
import { agentDisplayName, inferenceProviderDisplayName } from "@gotry-io/quota-protocol";
import { formatCost, formatCount, usageModelDisplayName } from "$lib/format";
import { type ModelColors, modelColor, OTHER_MODEL_COLOR } from "$lib/model-colors";
import { costPerMessageMicrousd, mergeCosts, type ModelRow, shareChange } from "$lib/model-usage";
import { cacheHitLabel } from "$lib/usage-metrics";

/**
 * The legend is the table ([`docs/design.md`](../../../../../docs/design.md), Model ledger): one
 * row per model merged across agents, each tinted by a bar of its tokens in the model colour.
 * Home shows six rows and then the rest as one; the Models page lists every model.
 */
let {
  rows,
  previous = null,
  colors,
  limit = 6,
  detail = false,
  selected = null,
  highlight = null,
  onHighlight,
  rowHref,
  moreHref,
  caption,
}: {
  rows: readonly ModelRow[];
  /** The previous period's rows, or null when this period has nothing to compare with. */
  previous?: readonly ModelRow[] | null;
  colors: ModelColors;
  /** Rows before the rest fold into **N more models**; null lists all. */
  limit?: number | null;
  /** The Models page's extra columns. */
  detail?: boolean;
  selected?: string | null;
  highlight?: string | null;
  onHighlight?: (key: string | null) => void;
  rowHref: (row: ModelRow) => string;
  moreHref?: string;
  caption: string;
} = $props();

const total = $derived(rows.reduce((sum, row) => sum + row.totals.total_tokens, 0));
const largest = $derived(rows[0]?.totals.total_tokens ?? 1);
const shown = $derived(limit === null ? rows : rows.slice(0, limit));
const rest = $derived(limit === null ? [] : rows.slice(limit));
const restTokens = $derived(rest.reduce((sum, row) => sum + row.totals.total_tokens, 0));

function share(tokens: number): string {
  return total > 0 ? `${((tokens / total) * 100).toFixed(1)}%` : "—";
}

function perMessage(row: ModelRow): string {
  const microusd = costPerMessageMicrousd(row);
  if (microusd === null) return "—";
  return `${row.cost.status === "partial" ? "≥ " : ""}$${(microusd / 1_000_000).toFixed(3)}`;
}
</script>

<div class="ledger-scroll">
  <table class="ledger">
    <caption class="visually-hidden">{caption}</caption>
    <thead>
      <tr>
        <th scope="col">Model</th>
        <th scope="col">Tokens</th>
        <th scope="col">Share</th>
        <th scope="col" class="wide">vs previous</th>
        <th scope="col" class="wide">From cache</th>
        <th scope="col">Cost</th>
        {#if detail}
          <th scope="col" class="wide">Messages</th>
          <th scope="col" class="wide">Per message</th>
        {/if}
      </tr>
    </thead>
    <tbody>
      {#each shown as row (row.key)}
        {@const color = modelColor(colors, row.provider, row.model)}
        {@const change = shareChange(row, total, previous)}
        <tr
          class:selected={selected === row.key}
          class:lit={highlight === row.key}
          data-model={row.model}
          onpointerenter={() => onHighlight?.(row.key)}
          onpointerleave={() => onHighlight?.(null)}
          onfocusin={() => onHighlight?.(row.key)}
          onfocusout={() => onHighlight?.(null)}
        >
          <th scope="row">
            <span
              class="fill"
              style:width={`${(row.totals.total_tokens / largest) * 100}%`}
              style:background={color}
            ></span>
            <span class="name">
              <i class="swatch" style:background={color}></i>
              <a class="model" href={rowHref(row)} aria-current={selected === row.key ? "true" : undefined}
                >{usageModelDisplayName(row.model)}</a
              >
              <span class="vendor">{inferenceProviderDisplayName(row.provider)}</span>
              <span class="agents">
                {#each row.agents as sent (sent.agent)}
                  <span>{agentDisplayName(sent.agent)}</span>
                {/each}
              </span>
            </span>
          </th>
          <td>{formatCount(row.totals.total_tokens)}</td>
          <td>{share(row.totals.total_tokens)}</td>
          <td class="wide">
            {#if change.kind === "new"}
              <span class="new">New</span>
            {:else if change.kind === "points"}
              <span class="change"
                >{change.points > 0 ? "↑" : change.points < 0 ? "↓" : ""}
                {Math.abs(change.points)} pts</span
              >
            {:else}
              <span class="dim">—</span>
            {/if}
          </td>
          <td class="wide">{cacheHitLabel(row.totals) ?? "—"}</td>
          <td>{formatCost(row.cost)}</td>
          {#if detail}
            <td class="wide">{formatCount(row.totals.messages)}</td>
            <td class="wide">{perMessage(row)}</td>
          {/if}
        </tr>
      {/each}
      {#if rest.length > 0}
        <tr class="rest">
          <th scope="row">
            <span class="name">
              <i class="swatch" style:background={OTHER_MODEL_COLOR}></i>
              {#if moreHref}
                <a class="more" href={moreHref}>{rest.length} more {rest.length === 1 ? "model" : "models"}</a>
              {:else}
                <span>{rest.length} more {rest.length === 1 ? "model" : "models"}</span>
              {/if}
            </span>
          </th>
          <td>{formatCount(restTokens)}</td>
          <td>{share(restTokens)}</td>
          <td class="wide"></td>
          <td class="wide"></td>
          <td>{formatCost(mergeCosts(rest.map((row) => row.cost)))}</td>
          {#if detail}
            <td class="wide"></td>
            <td class="wide"></td>
          {/if}
        </tr>
      {/if}
    </tbody>
  </table>
</div>

<style>
.ledger-scroll {
  overflow-x: auto;
}

.ledger {
  width: 100%;
  border-collapse: collapse;
  font-size: 13.5px;
}

th,
td {
  height: 44px;
  padding: 0 10px;
  border-bottom: 1px solid var(--hairline);
  text-align: right;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}

thead th {
  height: auto;
  padding: 8px 10px;
  color: var(--body);
  font-size: 12px;
  font-weight: 500;
}

thead th:first-child,
tbody th {
  padding-left: 0;
  text-align: left;
}

tbody th {
  position: relative;
  font-weight: 400;
}

tbody tr:hover > *,
tbody tr.lit > *,
tbody tr.selected > * {
  background: var(--hover);
}

.fill {
  position: absolute;
  top: 8px;
  bottom: 8px;
  left: 0;
  z-index: 0;
  border-radius: 6px;
  opacity: 0.16;
}

.name {
  position: relative;
  z-index: 1;
  display: flex;
  gap: 10px;
  align-items: center;
}

.swatch {
  flex: none;
  width: 10px;
  height: 10px;
  border-radius: 3px;
}

.model {
  color: var(--ink);
  font: 600 12.5px var(--mono);
  text-decoration: none;
}

.model:hover,
.more:hover {
  text-decoration: underline;
}

.model::after {
  position: absolute;
  inset: 0;
  content: "";
}

.more {
  color: var(--body);
  font-weight: 500;
  text-decoration: none;
}

.vendor {
  color: var(--charcoal);
  font-size: 12px;
}

.agents {
  display: inline-flex;
  gap: 4px;
}

.agents span {
  padding: 0 6px;
  border: 1px solid var(--hairline);
  border-radius: 9999px;
  color: var(--charcoal);
  font-size: 10.5px;
  font-weight: 500;
  line-height: 16px;
}

.change {
  color: var(--body);
  font-size: 12px;
}

.new {
  color: var(--brand);
  font-size: 12px;
  font-weight: 600;
}

.dim {
  color: var(--muted);
}

@media (max-width: 768px) {
  .wide,
  .agents,
  .vendor {
    display: none;
  }
}
</style>
