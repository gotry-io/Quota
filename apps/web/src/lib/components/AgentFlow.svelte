<script lang="ts">
import { agentDisplayName } from "@gotry-io/quota-protocol";
import { formatCount, usageModelDisplayName } from "$lib/format";
import { type ModelColors, modelColor } from "$lib/model-colors";
import type { AgentModelFlow } from "$lib/model-usage";

/**
 * Agents on the left in ink, models on the right in their colours, ribbons as wide as the tokens
 * one sent to the other ([`docs/design.md`](../../../../../docs/design.md), Agents → models).
 * Where it is too narrow to draw, the same pairs are a grouped list.
 */
let { flow, colors }: { flow: AgentModelFlow; colors: ModelColors } = $props();

let width = $state(1080);
const narrow = $derived(width < 640);
const H = $derived(
  Math.max(160, Math.min(320, 36 * Math.max(flow.models.length, flow.agents.length))),
);
const GAP = 9;
const NODE = 8;
const x0 = 150;
const x1 = $derived(width - 250);
const total = $derived(flow.agents.reduce((sum, item) => sum + item.tokens, 0));

const layout = $derived.by(() => {
  if (total <= 0) return null;
  const agentScale = (H - GAP * (flow.agents.length - 1)) / total;
  const modelScale = (H - GAP * (flow.models.length - 1)) / total;
  const agentTop = new Map<string, number>();
  const agents = [];
  let y = 0;
  for (const item of flow.agents) {
    const h = item.tokens * agentScale;
    agents.push({ ...item, y, h });
    agentTop.set(item.agent, y);
    y += h + GAP;
  }
  const modelTokens = new Map<string, number>();
  for (const link of flow.links) {
    modelTokens.set(link.key, (modelTokens.get(link.key) ?? 0) + link.tokens);
  }
  const models = [];
  const ribbons = [];
  let ym = 0;
  for (const row of flow.models) {
    const tokens = modelTokens.get(row.key) ?? 0;
    const h = tokens * modelScale;
    let offset = ym;
    for (const link of flow.links.filter((item) => item.key === row.key)) {
      const ha = link.tokens * agentScale;
      const hm = link.tokens * modelScale;
      const ay = agentTop.get(link.agent) ?? 0;
      const cx = (x0 + x1) / 2;
      ribbons.push({
        id: `${link.agent}>${row.key}`,
        color: modelColor(colors, row.provider, row.model),
        d: `M${x0},${ay} C${cx},${ay} ${cx},${offset} ${x1},${offset} L${x1},${offset + hm} C${cx},${offset + hm} ${cx},${ay + ha} ${x0},${ay + ha} Z`,
      });
      agentTop.set(link.agent, ay + ha);
      offset += hm;
    }
    models.push({ row, tokens, y: ym, h, color: modelColor(colors, row.provider, row.model) });
    ym += h + GAP;
  }
  return { agents, models, ribbons };
});

const pairs = $derived(
  flow.agents.map((item) => ({
    agent: item.agent,
    tokens: item.tokens,
    models: flow.links
      .filter((link) => link.agent === item.agent)
      .map((link) => ({ link, row: flow.models.find((row) => row.key === link.key) }))
      .filter((pair) => pair.row !== undefined)
      .sort((left, right) => right.link.tokens - left.link.tokens),
  })),
);
</script>

<div class="flow" bind:clientWidth={width}>
  {#if layout && !narrow}
    <svg viewBox="-4 -4 {width + 8} {H + 10}" width={width} height={H + 10} aria-hidden="true">
      {#each layout.ribbons as ribbon (ribbon.id)}
        <path class="ribbon" d={ribbon.d} fill={ribbon.color} />
      {/each}
      {#each layout.agents as node (node.agent)}
        <rect x={x0 - NODE} y={node.y} width={NODE} height={Math.max(node.h, 1.5)} rx="2" class="agent-node" />
        <text x={x0 - NODE - 10} y={node.y + node.h / 2 + (node.h > 24 ? 0 : 4)} text-anchor="end">{agentDisplayName(node.agent)}</text>
        {#if node.h > 24}
          <text class="sub" x={x0 - NODE - 10} y={node.y + node.h / 2 + 15} text-anchor="end">{formatCount(node.tokens)}</text>
        {/if}
      {/each}
      {#each layout.models as node (node.row.key)}
        <rect x={x1} y={node.y} width={NODE} height={Math.max(node.h, 1.5)} rx="2" fill={node.color} />
        <text class="model" x={x1 + NODE + 10} y={node.y + Math.max(node.h, 9) / 2 + 4}
          >{usageModelDisplayName(node.row.model)} <tspan class="sub">{formatCount(node.tokens)}</tspan></text
        >
      {/each}
    </svg>
  {/if}
  <ul class:visually-hidden={!narrow} class="pairs">
    {#each pairs as group (group.agent)}
      <li>
        <b>{agentDisplayName(group.agent)}</b> <span class="sub">{formatCount(group.tokens)}</span>
        <ul>
          {#each group.models as pair (pair.link.key)}
            {#if pair.row}
              <li>
                <i style:background={modelColor(colors, pair.row.provider, pair.row.model)}></i>
                <span class="model-name">{usageModelDisplayName(pair.row.model)}</span>
                <span class="sub">{formatCount(pair.link.tokens)} tokens</span>
              </li>
            {/if}
          {/each}
        </ul>
      </li>
    {/each}
  </ul>
</div>

<style>
.flow {
  min-width: 0;
}

svg {
  display: block;
  width: 100%;
  height: auto;
  overflow: visible;
}

text {
  fill: var(--ink);
  font: 12px var(--sans);
}

text.model {
  font: 11.5px var(--mono);
}

.sub {
  fill: var(--body);
  color: var(--body);
  font-size: 11px;
}

.agent-node {
  fill: var(--ink);
}

.ribbon {
  opacity: 0.5;
  transition: opacity 0.12s;
}

svg:hover .ribbon {
  opacity: 0.18;
}

svg .ribbon:hover {
  opacity: 0.85;
}

.pairs {
  display: grid;
  gap: 12px;
  margin: 0;
  padding: 0;
  list-style: none;
}

.pairs ul {
  display: grid;
  gap: 4px;
  margin: 6px 0 0;
  padding: 0;
  list-style: none;
}

.pairs li li {
  display: flex;
  gap: 8px;
  align-items: center;
  font-size: 13px;
}

.pairs i {
  flex: none;
  width: 10px;
  height: 10px;
  border-radius: 3px;
}

.model-name {
  font-family: var(--mono);
  font-size: 12px;
}

@media (prefers-reduced-motion: reduce) {
  .ribbon {
    transition: none;
  }
}
</style>
