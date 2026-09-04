<script lang="ts">
import { isBalanceOnly, remainingPercent, showsPercentMeter } from "@gotry-io/quota-model";
import { formatQuotaRemaining, NO_RESET_TIME_COPY, resetCopy, showsNoResetTime } from "$lib/format";

type WindowItem = {
  id?: string | undefined;
  title: string;
  used_percent: number;
  remaining_value?: number | undefined;
  limit_value?: number | undefined;
  value_unit?: string | undefined;
  resets_at?: string | undefined;
};

let {
  windows,
  provider,
  now,
}: {
  windows: readonly WindowItem[];
  provider?: string;
  now?: Date;
} = $props();
</script>

<div class="quota-window-list">
  {#if windows.length === 0}
    <p class="empty-state">No quota windows reported.</p>
  {:else}
    {#each windows as window (window.title)}
      {@const balanceOnly = isBalanceOnly(window)}
      {@const remaining = remainingPercent(window.used_percent)}
      {@const reset = window.resets_at ? resetCopy(window.resets_at, now) : null}
      <div class="quota-window-card">
        <div class="quota-window-heading">
          <span>{balanceOnly ? "Balance" : window.title}</span>
          <strong>{formatQuotaRemaining(window, provider)}</strong>
        </div>
        {#if showsPercentMeter(window)}
          <div class="quota-track">
            <span style:width={`${remaining}%`} aria-hidden="true"></span>
          </div>
        {/if}
        {#if reset}
          <p class="quota-window-meta">{reset}</p>
        {:else if !window.resets_at && showsNoResetTime(window)}
          <p class="quota-window-meta">{NO_RESET_TIME_COPY}</p>
        {/if}
      </div>
    {/each}
  {/if}
</div>
