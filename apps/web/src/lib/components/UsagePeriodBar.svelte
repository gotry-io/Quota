<script lang="ts">
import {
  nextUsagePeriod,
  previousUsagePeriod,
  USAGE_PERIOD_SEGMENTS,
  type UsageDateRange,
  usagePeriodForSegment,
  usagePeriodRange,
  type UsagePeriodSegment,
  type UsagePeriodSelection,
  usagePeriodTitle,
} from "$lib/usage-period";

let {
  selection,
  today,
  earliest,
  onSelect,
}: {
  selection: UsagePeriodSelection;
  today: Date;
  /** The first day the activity read covers, which is as far back as a custom range may reach. */
  earliest: string;
  onSelect: (selection: UsagePeriodSelection) => void;
} = $props();

let pickerOpen = $state(false);
let draft = $state<UsageDateRange>({ from: "", to: "" });

const latest = $derived(usagePeriodRange({ segment: "day", offset: 0 }, today)?.to ?? earliest);
const current = $derived(usagePeriodRange(selection, today));
const previous = $derived(previousUsagePeriod(selection));
const next = $derived(nextUsagePeriod(selection));
const title = $derived(usagePeriodTitle(selection, today));
const draftValid = $derived(
  draft.from !== "" && draft.to !== "" && draft.from <= draft.to && draft.from >= earliest,
);

function choose(segment: UsagePeriodSegment): void {
  if (segment === "custom") {
    draft = { from: current?.from ?? earliest, to: current?.to ?? latest };
    pickerOpen = true;
    return;
  }
  pickerOpen = false;
  onSelect(usagePeriodForSegment(segment, null));
}

function applyCustom(event: SubmitEvent): void {
  event.preventDefault();
  if (!draftValid) return;
  pickerOpen = false;
  onSelect({ segment: "custom", from: draft.from, to: draft.to });
}
</script>

<div class="period-bar">
  <div class="period-tabs" role="group" aria-label="Usage period">
    {#each USAGE_PERIOD_SEGMENTS as item (item.segment)}
      <button
        class="period-tab"
        type="button"
        aria-label={item.name}
        aria-pressed={selection.segment === item.segment}
        onclick={() => choose(item.segment)}>{item.label}</button
      >
    {/each}
  </div>
  <div class="period-step">
    <button
      class="period-arrow"
      type="button"
      aria-label="Previous period"
      disabled={previous === null}
      onclick={() => previous && onSelect(previous)}>‹</button
    >
    <span class="period-title" id="usage-period-title" aria-live="polite">{title}</span>
    <button
      class="period-arrow"
      type="button"
      aria-label="Next period"
      disabled={next === null}
      onclick={() => next && onSelect(next)}>›</button
    >
  </div>
</div>

{#if pickerOpen}
  <form class="period-picker" onsubmit={applyCustom} aria-label="Custom range">
    <label>
      <span>From</span>
      <input type="date" bind:value={draft.from} min={earliest} max={latest} required />
    </label>
    <label>
      <span>To</span>
      <input type="date" bind:value={draft.to} min={earliest} max={latest} required />
    </label>
    <button class="button-primary" type="submit" disabled={!draftValid}>Apply</button>
    <button class="button-secondary" type="button" onclick={() => (pickerOpen = false)}>
      Cancel
    </button>
  </form>
{/if}
