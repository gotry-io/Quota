<script lang="ts">
import {
  type UsageExportInput,
  usageExportCsv,
  usageExportFilename,
  usageExportJsonText,
} from "$lib/usage-export";
import {
  nextUsagePeriod,
  previousUsagePeriod,
  USAGE_PERIOD_MORE,
  USAGE_PERIOD_PRIMARY,
  USAGE_PERIOD_SEGMENTS,
  type UsageDateRange,
  usagePeriodForSegment,
  usagePeriodRange,
  type UsagePeriodSegment,
  type UsagePeriodSelection,
  usagePeriodTitle,
} from "$lib/usage-period";

/**
 * The period control in a page header: Today · 7D · 30D · 90D as segments, the other periods and
 * the period export under **More**, and Previous / Next period beside the dates when the period
 * steps a day, week, or month at a time.
 */
let {
  selection,
  today,
  earliest,
  onSelect,
  exportInput = undefined,
}: {
  selection: UsagePeriodSelection;
  today: Date;
  /** The first day a custom range may start on. */
  earliest: string;
  onSelect: (selection: UsagePeriodSelection) => void;
  /** The loaded period body to export; undefined leaves Export out of the menu. */
  exportInput?: UsageExportInput | null | undefined;
} = $props();

const uid = $props.id();
let menuOpen = $state(false);
let pickerOpen = $state(false);
let draft = $state<UsageDateRange>({ from: "", to: "" });
let root = $state<HTMLDivElement | null>(null);
let moreButton = $state<HTMLButtonElement | null>(null);
let menu = $state<HTMLDivElement | null>(null);

const latest = $derived(usagePeriodRange({ segment: "day", offset: 0 }, today)?.to ?? earliest);
const previous = $derived(previousUsagePeriod(selection));
const next = $derived(nextUsagePeriod(selection));
const steps = $derived(previous !== null);
const draftValid = $derived(
  draft.from !== "" && draft.to !== "" && draft.from <= draft.to && draft.from >= earliest,
);
const moreActive = $derived(USAGE_PERIOD_MORE.includes(selection.segment));

function entry(segment: UsagePeriodSegment) {
  return USAGE_PERIOD_SEGMENTS.find((item) => item.segment === segment);
}

function shortLabel(segment: UsagePeriodSegment): string {
  return segment === "day" ? "Today" : (entry(segment)?.label ?? segment);
}

$effect(() => {
  if (!menuOpen && !pickerOpen) return;
  const onPointerDown = (event: PointerEvent): void => {
    if (event.target instanceof Node && root && !root.contains(event.target)) {
      menuOpen = false;
      pickerOpen = false;
    }
  };
  document.addEventListener("pointerdown", onPointerDown);
  return () => document.removeEventListener("pointerdown", onPointerDown);
});

$effect(() => {
  if (menuOpen) menu?.querySelector<HTMLButtonElement>("[role=menuitem]")?.focus();
});

function choose(segment: UsagePeriodSegment): void {
  menuOpen = false;
  if (segment === "custom") {
    const current = usagePeriodRange(selection, today);
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

function download(format: "csv" | "json"): void {
  menuOpen = false;
  if (!exportInput) return;
  const body = format === "csv" ? usageExportCsv(exportInput) : usageExportJsonText(exportInput);
  const type = format === "csv" ? "text/csv;charset=utf-8" : "application/json;charset=utf-8";
  const url = URL.createObjectURL(new Blob([body], { type }));
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = usageExportFilename(exportInput.from, exportInput.to, format);
  document.body.append(anchor);
  anchor.click();
  anchor.remove();
  URL.revokeObjectURL(url);
}

function onMenuKey(event: KeyboardEvent): void {
  if (event.key === "Escape") {
    event.preventDefault();
    menuOpen = false;
    moreButton?.focus();
    return;
  }
  if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
  event.preventDefault();
  const items = [
    ...(menu?.querySelectorAll<HTMLButtonElement>("[role=menuitem]:not(:disabled)") ?? []),
  ];
  const at = items.indexOf(document.activeElement as HTMLButtonElement);
  const step = event.key === "ArrowDown" ? 1 : -1;
  items[(at + step + items.length) % items.length]?.focus();
}
</script>

<div class="period-control" bind:this={root}>
  {#if steps}
    <div class="period-step">
      <button
        class="pill sm step"
        type="button"
        aria-label="Previous period"
        onclick={() => previous && onSelect(previous)}>‹</button
      >
      <span class="period-dates" aria-live="polite">{usagePeriodTitle(selection, today)}</span>
      <button
        class="pill sm step"
        type="button"
        aria-label="Next period"
        disabled={next === null}
        onclick={() => next && onSelect(next)}>›</button
      >
    </div>
  {/if}
  <div class="seg" role="group" aria-label="Usage period">
    {#each USAGE_PERIOD_PRIMARY as segment (segment)}
      <button
        type="button"
        aria-label={entry(segment)?.name}
        aria-pressed={selection.segment === segment}
        onclick={() => choose(segment)}>{shortLabel(segment)}</button
      >
    {/each}
  </div>
  <div class="more">
    <button
      bind:this={moreButton}
      class="pill"
      class:active={moreActive}
      type="button"
      aria-haspopup="menu"
      aria-expanded={menuOpen}
      aria-controls="{uid}-menu"
      onclick={() => {
        menuOpen = !menuOpen;
        pickerOpen = false;
      }}
      >{moreActive ? entry(selection.segment)?.name : "More"} <span aria-hidden="true">▾</span></button
    >
    {#if menuOpen}
      <div class="popover" role="menu" id="{uid}-menu" tabindex="-1" bind:this={menu} onkeydown={onMenuKey}>
        {#each USAGE_PERIOD_MORE as segment (segment)}
          <button
            type="button"
            role="menuitemradio"
            aria-checked={selection.segment === segment}
            onclick={() => choose(segment)}
            >{entry(segment)?.name}{segment === "custom" ? "…" : ""}</button
          >
        {/each}
        {#if exportInput !== undefined}
          <hr />
          <button type="button" role="menuitem" disabled={exportInput === null} onclick={() => download("csv")}
            >Export CSV <small>same dates and zone</small></button
          >
          <button type="button" role="menuitem" disabled={exportInput === null} onclick={() => download("json")}
            >Export JSON</button
          >
          {#if exportInput === null}
            <p class="menu-note">Export needs a period with daily totals.</p>
          {/if}
        {/if}
      </div>
    {/if}
    {#if pickerOpen}
      <form class="popover picker" onsubmit={applyCustom} aria-label="Custom range">
        <label>
          <span>From</span>
          <input class="input" type="date" bind:value={draft.from} min={earliest} max={latest} required />
        </label>
        <label>
          <span>To</span>
          <input class="input" type="date" bind:value={draft.to} min={earliest} max={latest} required />
        </label>
        <div class="picker-actions">
          <button class="pill" type="button" onclick={() => (pickerOpen = false)}>Cancel</button>
          <button class="pill primary" type="submit" disabled={!draftValid}>Apply</button>
        </div>
      </form>
    {/if}
  </div>
</div>

<style>
.period-control {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  align-items: center;
  justify-content: flex-end;
}

.period-step {
  display: flex;
  gap: 6px;
  align-items: center;
}

.step {
  min-width: 32px;
  padding: 0;
  font-size: 16px;
}

.period-dates {
  color: var(--body);
  font-size: 12.5px;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}

.more {
  position: relative;
}

.more .active {
  border-color: var(--ink);
}

.popover {
  position: absolute;
  top: calc(100% + 6px);
  right: 0;
  z-index: 30;
  display: grid;
  min-width: 220px;
  padding: 6px;
  border: 1px solid var(--strong);
  border-radius: 12px;
  background: var(--canvas);
}

.popover [role^="menuitem"] {
  display: flex;
  gap: 8px;
  align-items: baseline;
  justify-content: space-between;
  min-height: 34px;
  padding: 0 10px;
  border: 0;
  border-radius: 8px;
  background: transparent;
  font-size: 13px;
  text-align: left;
  cursor: pointer;
}

.popover [role^="menuitem"]:hover:not(:disabled),
.popover [role^="menuitem"]:focus-visible {
  background: var(--hover);
}

.popover [role="menuitemradio"][aria-checked="true"] {
  font-weight: 600;
}

.popover [role^="menuitem"]:disabled {
  color: var(--muted);
  cursor: not-allowed;
}

.popover small {
  color: var(--body);
  font-size: 11px;
}

hr {
  width: 100%;
  margin: 4px 0;
  border: 0;
  border-top: 1px solid var(--hairline);
}

.menu-note {
  padding: 4px 10px;
  color: var(--body);
  font-size: 11.5px;
}

.picker {
  gap: 10px;
  width: 260px;
  padding: 12px;
}

.picker label {
  display: grid;
  gap: 4px;
  color: var(--body);
  font-size: 12px;
}

.picker-actions {
  display: flex;
  gap: 8px;
  justify-content: flex-end;
}

@media (max-width: 768px) {
  .period-control {
    justify-content: flex-start;
  }

  .seg button {
    min-height: 34px;
  }
}
</style>
