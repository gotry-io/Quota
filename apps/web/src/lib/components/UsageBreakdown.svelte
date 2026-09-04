<script lang="ts">
import type { UsagePeriodRead } from "@gotry-io/quota-protocol";
import { agentDisplayName, inferenceProviderDisplayName } from "@gotry-io/quota-protocol";
import { formatCost, formatCount, usageModelDisplayName } from "$lib/format";
import { hiddenModelCount, USAGE_MODEL_FOLD_LIMIT } from "$lib/usage-period";

let { period }: { period: UsagePeriodRead } = $props();

let expanded = $state<Record<string, boolean>>({});

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
  <div class="table-wrap">
    <table class="usage-tree" id="usage-breakdown">
      <caption class="visually-hidden">Usage by agent, provider, and model</caption>
      <thead>
        <tr>
          <th scope="col">Model</th>
          <th scope="col">Tokens</th>
          <th scope="col">Cost</th>
        </tr>
      </thead>
      {#each period.agents as agent (agent.agent)}
        <tbody>
          <tr class="usage-group-agent">
            <th scope="rowgroup" colspan="3">{agentDisplayName(agent.agent)}</th>
          </tr>
          {#each agent.providers as provider (provider.provider)}
            {@const extra = hiddenModelCount(provider.models.length)}
            {@const open = isExpanded(agent.agent, provider.provider)}
            {@const visible = open
              ? provider.models
              : provider.models.slice(0, USAGE_MODEL_FOLD_LIMIT)}
            <tr class="usage-group-provider">
              <th scope="rowgroup" colspan="3">{inferenceProviderDisplayName(provider.provider)}</th>
            </tr>
            {#each visible as model (model.model)}
              <tr>
                <th scope="row">{usageModelDisplayName(model.model)}</th>
                <td>{formatCount(model.totals.total_tokens)}</td>
                <td>{formatCost(model.cost)}</td>
              </tr>
            {/each}
            {#if extra > 0}
              <tr>
                <td colspan="3">
                  <button
                    class="text-button usage-show-more"
                    type="button"
                    aria-expanded={open}
                    onclick={() => toggleGroup(agent.agent, provider.provider)}
                    >Show {extra} more</button
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
