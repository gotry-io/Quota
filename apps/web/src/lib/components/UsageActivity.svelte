<script lang="ts">
import type { UsageActivityDayRead, UsagePeriodRead } from "@gotry-io/quota-protocol";
import {
  type AccountError,
  accountNoticeActionLabel,
  accountNoticeRetry,
} from "$lib/account-errors";
import LoadingBlock from "$lib/components/LoadingBlock.svelte";
import RetryNotice from "$lib/components/RetryNotice.svelte";
import UsageBreakdown from "$lib/components/UsageBreakdown.svelte";
import { costBasisLabel, formatCost, formatCount } from "$lib/format";
import {
  ACTIVITY_WEEKDAY_LABELS,
  type ActivityRange,
  activityRoverFromKey,
  buildUsageActivityModel,
  formatActivityDate,
  nextActivityDate,
  placeActivityTooltip,
} from "$lib/usage-activity";

let {
  days,
  range,
  selectedDate = null,
  detail = null,
  detailError = null,
  detailLoading = false,
  onSelectDate,
  onClose,
  onRetryDetail,
}: {
  days: UsageActivityDayRead[];
  range: ActivityRange;
  selectedDate?: string | null;
  detail?: UsageActivityDayRead | null;
  detailError?: AccountError | null;
  detailLoading?: boolean;
  onSelectDate: (date: string) => void;
  onClose: () => void;
  onRetryDetail: () => void;
} = $props();

const model = $derived(buildUsageActivityModel(days, range, range.to));
const selected = $derived(
  selectedDate
    ? (model.days.find((item) => item.date === selectedDate && !item.outside) ?? null)
    : null,
);
const selectedCost = $derived(
  selected?.cost ?? { amount_microusd: null, status: "unavailable", basis: "none" },
);
const detailAgents = $derived(detail?.agents ?? []);
const detailPeriod = $derived.by((): UsagePeriodRead | null => {
  if (!detail || detailAgents.length === 0) return null;
  return {
    totals: detail.totals,
    cost: detail.cost,
    partial: false,
    agents: detailAgents,
  };
});

let roverOverride = $state<string | null>(null);
const roverDate = $derived.by(() => {
  const selectable = model.days.filter((day) => !day.outside).map((day) => day.date);
  if (roverOverride !== null && selectable.includes(roverOverride)) return roverOverride;
  if (selectedDate && selectable.includes(selectedDate)) return selectedDate;
  const today = model.days.find((day) => day.today);
  return today?.date ?? selectable.at(-1) ?? null;
});
let weeksEl = $state<HTMLDivElement | null>(null);
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
  if (found) {
    roverOverride = found.day.date;
    showTooltip(found.day, found.button);
  }
}

function focusDay(date: string): void {
  roverOverride = date;
  const button = weeksEl?.querySelector(`button.usage-activity-cell[data-date="${date}"]`);
  if (!(button instanceof HTMLButtonElement)) return;
  button.focus();
  const day = model.days.find((item) => item.date === date);
  if (day) showTooltip(day, button);
}

function onKeyDown(event: KeyboardEvent): void {
  if (!(event.target instanceof HTMLButtonElement)) return;
  if (!event.target.classList.contains("usage-activity-cell")) return;
  const date = event.target.dataset.date;
  if (!date) return;
  const action = activityRoverFromKey(event.key);
  if (action === null) return;
  event.preventDefault();
  if (action === "select") {
    onSelectDate(date);
    return;
  }
  const next = nextActivityDate(model.days, date, action);
  if (next !== date) focusDay(next);
}

function closePanel(): void {
  const date = selectedDate;
  if (date) focusDay(date);
  onClose();
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
            bind:this={weeksEl}
            class="usage-activity-weeks"
            role="group"
            aria-roledescription="grid"
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
                  tabindex={day.date === roverDate ? 0 : -1}
                  aria-pressed={day.date === selectedDate}
                  aria-label={day.tooltip}
                  onclick={() => onSelectDate(day.date)}
                  onkeydown={onKeyDown}
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
  {#if selected}
    <section class="usage-activity-detail" aria-labelledby="usage-activity-day-title">
      <div class="usage-activity-detail-header">
        <div>
          <h3 id="usage-activity-day-title">{formatActivityDate(selected.date)}</h3>
          <p class="usage-activity-detail-meta">UTC</p>
        </div>
        <button class="text-button usage-activity-detail-close" type="button" onclick={closePanel}
          >Close</button
        >
      </div>
      <div class="usage-activity-detail-stats">
        <article>
          <span>Tokens</span>
          <strong>{formatCount(selected.tokens)}</strong>
          <small
            >{`${formatCount(selected.input_tokens)} in · ${formatCount(selected.output_tokens)} out · ${formatCount(selected.requests)} requests`}</small
          >
        </article>
        <article>
          <span>API-equivalent cost</span>
          <strong>{formatCost(selectedCost)}</strong>
          <small>{costBasisLabel(selectedCost)}</small>
        </article>
      </div>
      {#if selected.partial}
        <p class="usage-day-note">Some hours on this day were scanned incompletely.</p>
      {/if}
      {#if detailLoading}
        <LoadingBlock lines={3} label="Loading this day's Usage" />
      {:else if detailError}
        <RetryNotice
          message={detailError.message}
          actionLabel={accountNoticeActionLabel(detailError)}
          onRetry={accountNoticeRetry(detailError, onRetryDetail)}
        />
      {:else if detailPeriod}
        <UsageBreakdown period={detailPeriod} id="usage-day-breakdown" />
      {:else}
        <p class="empty-state">No Usage on this day.</p>
      {/if}
    </section>
  {/if}
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
