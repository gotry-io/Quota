<script lang="ts">
import { formatDate, formatQuotaRemaining } from "$lib/format";

type WindowItem = {
  id?: string | undefined;
  title: string;
  used_percent: number;
  remaining_value?: number | undefined;
  limit_value?: number | undefined;
  value_unit?: string | undefined;
  resets_at?: string | undefined;
};

let { windows, provider }: { windows: readonly WindowItem[]; provider?: string } = $props();

function isBalanceOnly(window: WindowItem): boolean {
  return window.remaining_value !== undefined && window.limit_value === undefined;
}
</script>

<div class="quota-window-list">
  {#if windows.length === 0}
    <p class="empty-state">No quota windows reported.</p>
  {:else}
    {#each windows as window (window.title)}
      {@const balanceOnly = isBalanceOnly(window)}
      <div class="quota-window-card">
        <div class="quota-window-heading">
          <span>{balanceOnly ? "Balance" : window.title}</span>
          <strong>{formatQuotaRemaining(window, provider)}</strong>
        </div>
        {#if !balanceOnly}
          <div class="quota-track">
            <span
              style:width={`${Math.max(0, Math.min(100, 100 - window.used_percent))}%`}
              aria-hidden="true"
            ></span>
          </div>
        {/if}
        {#if window.resets_at || !balanceOnly}
          <p class="quota-window-meta">
            {window.resets_at ? `Resets ${formatDate(window.resets_at)}` : "No reset time reported"}
          </p>
        {/if}
      </div>
    {/each}
  {/if}
</div>
