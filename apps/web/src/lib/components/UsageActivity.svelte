<script lang="ts">
import type { AccountSummaryV3 as AccountSummary, UsageBreakdown } from "@gotry-io/quota-protocol";
import {
  ACTIVITY_WEEKDAY_LABELS,
  buildUsageActivityModel,
  placeActivityTooltip,
} from "$lib/usage-activity";

let {
  breakdowns,
  range,
  selectedDate = null,
  onSelectDate,
}: {
  breakdowns: UsageBreakdown[];
  range: AccountSummary["usage"]["range"];
  selectedDate?: string | null;
  onSelectDate: (date: string) => void;
} = $props();

const model = $derived(
  buildUsageActivityModel(breakdowns, range, new Date().toISOString().slice(0, 10)),
);

let tooltipText = $state<string | null>(null);
let tooltipAnchor = $state<HTMLElement | null>(null);
let tooltipEl = $state<HTMLDivElement | null>(null);
let tooltipBox = $state<{ left: number; top: number } | null>(null);

function dayFromTarget(
  target: EventTarget | null,
): { day: (typeof model.days)[number]; button: HTMLButtonElement } | null {
  if (!(target instanceof Element)) return null;
  const button = target.closest("button.usage-activity-cell");
  if (!(button instanceof HTMLButtonElement)) return null;
  const date = button.dataset.date;
  const day = date ? model.days.find((item) => item.date === date) : undefined;
  if (!day || day.outside) return null;
  return { day, button };
}

function showTooltip(day: (typeof model.days)[number], button: HTMLElement): void {
  tooltipText = day.tooltip;
  tooltipAnchor = button;
}

function hideTooltip(): void {
  tooltipText = null;
  tooltipAnchor = null;
  tooltipBox = null;
}

function onPointerOver(event: PointerEvent): void {
  const found = dayFromTarget(event.target);
  if (found) showTooltip(found.day, found.button);
  else hideTooltip();
}

function hideIfLeftGroup(event: PointerEvent | FocusEvent): void {
  const current = event.currentTarget;
  if (
    current instanceof Node &&
    event.relatedTarget instanceof Node &&
    current.contains(event.relatedTarget)
  ) {
    return;
  }
  hideTooltip();
}

function onFocusIn(event: FocusEvent): void {
  const found = dayFromTarget(event.target);
  if (found) showTooltip(found.day, found.button);
}

$effect(() => {
  if (!tooltipText || !tooltipAnchor || !tooltipEl) return;
  const anchor = tooltipAnchor;
  const layer = tooltipEl;
  const update = (): void => {
    const cell = anchor.getBoundingClientRect();
    const box = layer.getBoundingClientRect();
    const placed = placeActivityTooltip({
      cell,
      viewport: { width: window.innerWidth, height: window.innerHeight },
      tooltip: { width: box.width, height: box.height },
    });
    tooltipBox = { left: placed.left, top: placed.top };
  };
  update();
  window.addEventListener("scroll", update, true);
  window.addEventListener("resize", update);
  return () => {
    window.removeEventListener("scroll", update, true);
    window.removeEventListener("resize", update);
  };
});
</script>

<div class="usage-activity">
  <div class="usage-activity-card">
    <div class="usage-activity-scroll">
      <div class="usage-activity-chart">
        <div class="usage-activity-month-row">
          <span class="usage-activity-corner" aria-hidden="true"></span>
          <div
            class="usage-activity-months"
            style="grid-template-columns: repeat({model.weeks.length}, var(--activity-cell))"
          >
            {#each model.monthLabels as month (month.weekIndex)}
              <span
                class="usage-activity-month"
                style="grid-column: {month.weekIndex + 1} / span {month.span}">{month.label}</span
              >
            {/each}
          </div>
        </div>
        <div class="usage-activity-body">
          <div class="usage-activity-weekdays" aria-hidden="true">
            {#each ACTIVITY_WEEKDAY_LABELS as label, index (index)}
              <span>{label}</span>
            {/each}
          </div>
          <div
            class="usage-activity-weeks"
            role="group"
            aria-label="Usage activity by day"
            onpointerover={onPointerOver}
            onpointerout={hideIfLeftGroup}
            onfocusin={onFocusIn}
            onfocusout={hideIfLeftGroup}
          >
            {#each model.days as day (day.date)}
              {#if day.outside}
                <span class="usage-activity-cell activity-outside" aria-hidden="true"></span>
              {:else}
                <button
                  class="usage-activity-cell activity-level-{day.level}"
                  class:activity-today={day.today}
                  type="button"
                  data-date={day.date}
                  aria-label={day.tooltip}
                  aria-pressed={selectedDate === day.date}
                  aria-controls={selectedDate === day.date ? "usage-day-details" : undefined}
                  onclick={() => onSelectDate(day.date)}
                ></button>
              {/if}
            {/each}
          </div>
        </div>
      </div>
    </div>
    <div class="activity-legend" aria-hidden="true">
      <span>Less</span>
      <i class="usage-activity-cell activity-level-0"></i>
      <i class="usage-activity-cell activity-level-1"></i>
      <i class="usage-activity-cell activity-level-2"></i>
      <i class="usage-activity-cell activity-level-3"></i>
      <i class="usage-activity-cell activity-level-4"></i>
      <span>More</span>
    </div>
  </div>
  {#if tooltipText}
    <div
      bind:this={tooltipEl}
      class="usage-activity-tooltip"
      class:is-ready={tooltipBox !== null}
      aria-hidden="true"
      style:left={tooltipBox ? `${tooltipBox.left}px` : "0"}
      style:top={tooltipBox ? `${tooltipBox.top}px` : "0"}
    >
      {tooltipText}
    </div>
  {/if}
</div>
