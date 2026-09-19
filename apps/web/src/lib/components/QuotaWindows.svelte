<script lang="ts">
import {
  formatWindowTitle,
  quotaPace,
  remainingPercent,
  showsPercentMeter,
} from "@gotry-io/quota-model";
import { meterTone, quotaMeterName } from "$lib/account-overview";
import {
  formatQuotaRemaining,
  NO_RESET_TIME_COPY,
  paceDetail,
  paceHeadline,
  resetCopy,
  showsNoResetTime,
} from "$lib/format";

type WindowItem = {
  id: string;
  title: string;
  used_percent: number;
  remaining_value?: number | undefined;
  limit_value?: number | undefined;
  value_unit?: string | undefined;
  resets_at?: string | undefined;
  duration_seconds?: number | undefined;
};

let {
  windows,
  provider,
  now,
  showPaceDetail = false,
}: {
  windows: readonly WindowItem[];
  provider?: string;
  now?: Date;
  showPaceDetail?: boolean;
} = $props();
</script>

<div class="quota-window-list">
  {#if windows.length === 0}
    <p class="empty-state">No quota windows reported.</p>
  {:else}
    {#each windows as window (window.id)}
      {@const remaining = remainingPercent(window.used_percent)}
      {@const remainingText = formatQuotaRemaining(window, provider)}
      {@const title = formatWindowTitle(window.title, window)}
      {@const reset = window.resets_at ? resetCopy(window.resets_at, now) : null}
      {@const tone = meterTone(remaining)}
      {@const pace = quotaPace(window, now ?? new Date())}
      {@const headline = paceHeadline(pace, window.resets_at)}
      {@const detail = showPaceDetail && headline ? paceDetail(pace) : null}
      {@const showMeter = showsPercentMeter(window)}
      <div class="quota-window">
        {#if showMeter}
          <div
            class="quota-window-reading quota-window-reading-meter"
            role="meter"
            aria-valuemin="0"
            aria-valuemax="100"
            aria-valuenow={remaining}
            aria-label={quotaMeterName(title, remainingText)}
          >
            <span class="quota-window-title" aria-hidden="true">{title}</span>
            <strong class="quota-window-remaining" aria-hidden="true">{remainingText}</strong>
            <div class="quota-track meter-{tone}">
              <span style:width={`${remaining}%`}></span>
            </div>
          </div>
        {:else}
          <div class="quota-window-reading">
            <span class="quota-window-title">{title}</span>
            <strong class="quota-window-remaining">{remainingText}</strong>
          </div>
        {/if}
        {#if reset}
          <p class="quota-window-meta">{reset}</p>
        {:else if !window.resets_at && showsNoResetTime(window)}
          <p class="quota-window-meta">{NO_RESET_TIME_COPY}</p>
        {/if}
        {#if headline}
          <p class="quota-window-meta" class:quota-window-pace-warn={pace.kind === "runs_out"}>
            {headline}
          </p>
        {/if}
        {#if detail}
          <p class="quota-window-meta">{detail}</p>
        {/if}
      </div>
    {/each}
  {/if}
</div>
