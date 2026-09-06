<script lang="ts">
import type { UsagePeriodRead } from "@gotry-io/quota-protocol";
import { agentDisplayName, inferenceProviderDisplayName } from "@gotry-io/quota-protocol";
import { formatCost, formatCount, usageModelDisplayName } from "$lib/format";
import {
  shareFraction,
  shareLabel,
  usageModelShares,
  usageProviderShares,
} from "$lib/usage-metrics";
import { hiddenModelCount, USAGE_MODEL_FOLD_LIMIT } from "$lib/usage-period";

/**
 * The tree reads only what it draws: the totals a share is taken against, whether the period was
 * scanned whole, and the leaves. A day of the activity chart has those and no period beside it.
 */
let {
  period,
  id = "usage-breakdown",
}: {
  period: {
    totals: UsagePeriodRead["totals"];
    partial: boolean;
    agents: UsagePeriodRead["agents"];
  };
  id?: string;
} = $props();

let expanded = $state<Record<string, boolean>>({});

const total = $derived(period.totals.total_tokens);
const providers = $derived(usageProviderShares(period.agents));
const topModels = $derived(usageModelShares(period.agents).slice(0, 3));

function groupKey(agent: string, provider: string): string {
  return `${agent}/${provider}`;
}

function isExpanded(agent: string, provider: string): boolean {
  return expanded[groupKey(agent, provider)] === true;
}

function toggleGroup(agent: string, provider: string): void {
  const key = groupKey(agent, provider);
  expanded = { ...expanded, [key]: !isExpanded(agent, provider) };
}
</script>

{#if period.partial}
  <p class="usage-day-note">Some hours in this period were scanned incompletely.</p>
{/if}
{#if period.agents.length === 0}
  <p class="empty-state">No Usage in this period.</p>
{:else}
  {#if topModels.length > 0}
    <ol class="usage-top-models" id="{id}-top">
      {#each topModels as model (`${model.agent}/${model.provider}/${model.model}`)}
        <li>
          <span class="usage-top-model-name">{usageModelDisplayName(model.model)}</span>
          <span class="usage-top-model-value"
            >{shareLabel(model.tokens, total) ?? "—"} · {formatCount(model.tokens)}</span
          >
        </li>
      {/each}
    </ol>
  {/if}

  <ul class="usage-provider-shares" id="{id}-providers">
    {#each providers as provider (provider.provider)}
      <li>
        <span class="usage-provider-share-name"
          >{inferenceProviderDisplayName(provider.provider)}</span
        >
        <span class="usage-provider-share-track" aria-hidden="true">
          <i style:width="{shareFraction(provider.tokens, total) * 100}%"></i>
        </span>
        <span class="usage-provider-share-value">{shareLabel(provider.tokens, total) ?? "—"}</span>
      </li>
    {/each}
  </ul>

  <div class="table-wrap">
    <table class="usage-tree" {id}>
      <caption class="visually-hidden">Usage by agent, provider, and model</caption>
      <thead>
        <tr>
          <th scope="col">Model</th>
          <th scope="col">Tokens</th>
          <th scope="col">Share</th>
          <th scope="col">Cost</th>
        </tr>
      </thead>
      {#each period.agents as agent (agent.agent)}
        <tbody>
          <tr class="usage-group-agent">
            <th scope="rowgroup" colspan="4">{agentDisplayName(agent.agent)}</th>
          </tr>
          {#each agent.providers as provider (provider.provider)}
            {@const extra = hiddenModelCount(provider.models.length)}
            {@const open = isExpanded(agent.agent, provider.provider)}
            {@const visible = open
              ? provider.models
              : provider.models.slice(0, USAGE_MODEL_FOLD_LIMIT)}
            <tr class="usage-group-provider">
              <th scope="rowgroup" colspan="4">{inferenceProviderDisplayName(provider.provider)}</th>
            </tr>
            {#each visible as model (model.model)}
              <tr>
                <th scope="row">{usageModelDisplayName(model.model)}</th>
                <td>{formatCount(model.totals.total_tokens)}</td>
                <td>{shareLabel(model.totals.total_tokens, total) ?? "—"}</td>
                <td>{formatCost(model.cost)}</td>
              </tr>
            {/each}
            {#if extra > 0}
              <tr>
                <td colspan="4">
                  <button
                    class="text-button usage-show-more"
                    type="button"
                    aria-expanded={open}
                    onclick={() => toggleGroup(agent.agent, provider.provider)}
                    >{open ? "Show fewer" : `Show ${extra} more`}</button
                  >
                </td>
              </tr>
            {/if}
          {/each}
        </tbody>
      {/each}
    </table>
  </div>
{/if}
