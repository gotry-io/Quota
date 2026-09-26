<script lang="ts">
import { USAGE_OTHER_MODEL } from "@gotry-io/quota-protocol";
import { usageModelDisplayName } from "$lib/format";
import { type ModelColors, modelColor } from "$lib/model-colors";
import {
  monotonePath,
  type RiverData,
  type RiverMode,
  riverArrival,
  riverRuns,
  stackRiver,
} from "$lib/model-river";

/**
 * Stacked area by model per local day ([`docs/design.md`](../../../../../docs/design.md), Model
 * river). The ledger under it is the legend; labels at the right end name the bands tall enough
 * to hold one. Hover or arrow keys move a crosshair that reads out the day.
 */
let {
  data,
  mode = "amount",
  colors,
  format,
  label,
  height = 300,
  labels = true,
  annotate = true,
  highlight = null,
  onHighlight,
  fill,
}: {
  data: RiverData;
  mode?: RiverMode;
  colors: ModelColors;
  /** One value in the metric's words: `1.2M`, `$4.10`. */
  format: (value: number) => string;
  /** What the chart shows, as its accessible name. */
  label: string;
  height?: number;
  labels?: boolean;
  annotate?: boolean;
  /** The model key the ledger is pointing at; every other band fades. */
  highlight?: string | null;
  onHighlight?: (key: string | null) => void;
  /** A fixed fill for a stream that is not a model, such as messages. */
  fill?: string | undefined;
} = $props();

const uid = $props.id();
let width = $state(1080);
let active = $state<number | null>(null);

const narrow = $derived(width < 640);
const showLabels = $derived(labels && !narrow && data.bands.length > 0);
const L = 48;
const R = $derived(showLabels ? 168 : 8);
const T = 18;
const B = 24;
const stack = $derived(stackRiver(data, mode));
const top = $derived(mode === "share" ? 1 : stack.maximum * 1.08 || 1);
const count = $derived(data.dates.length);
const step = $derived(count > 1 ? (width - L - R) / (count - 1) : width - L - R);

function x(position: number): number {
  return count > 1 ? L + position * step : L + (width - L - R) / 2;
}

function y(value: number): number {
  return height - B - (value / top) * (height - B - T);
}

function colorOf(band: RiverData["bands"][number]): string {
  return fill ?? modelColor(colors, band.provider, band.model);
}

const runs = $derived(riverRuns(data, mode));

function bandPath(index: number): string {
  const lower = stack.lower[index] ?? [];
  const upper = stack.upper[index] ?? [];
  let path = "";
  for (const [start, end] of runs) {
    const span = [];
    for (let position = start; position <= end; position += 1) span.push(position);
    const half = count > 1 ? step / 4 : (width - L - R) / 2;
    const xs =
      span.length === 1 ? [x(start) - half, x(start) + half] : span.map((position) => x(position));
    const ups =
      span.length === 1 ? [upper[start] ?? 0, upper[start] ?? 0] : span.map((p) => upper[p] ?? 0);
    const lows =
      span.length === 1 ? [lower[start] ?? 0, lower[start] ?? 0] : span.map((p) => lower[p] ?? 0);
    const topEdge = xs.map((value, i) => [value, y(ups[i] ?? 0)] as const);
    const bottomEdge = xs.map((value, i) => [value, y(lows[i] ?? 0)] as const).reverse();
    path += `${monotonePath(topEdge)}${monotonePath(bottomEdge, false)}Z`;
  }
  return path;
}

const valueTicks = $derived(mode === "share" ? [0, 0.5, 1] : [0, stack.maximum / 2, stack.maximum]);

const dateTicks = $derived.by(() => {
  const every = Math.max(1, Math.round(count / (narrow ? 3 : 6)));
  const ticks: number[] = [];
  for (let position = 0; position < count; position += every) ticks.push(position);
  if (count > 1 && ticks.at(-1) !== count - 1) {
    if (count - 1 - (ticks.at(-1) ?? 0) < every / 2) ticks.pop();
    ticks.push(count - 1);
  }
  return ticks;
});

function dayLabel(position: number): string {
  const date = data.dates[position] ?? "";
  if (position === data.inProgress) return "Today";
  return new Date(`${date}T00:00:00Z`).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    timeZone: "UTC",
  });
}

const endLabels = $derived.by(() => {
  if (!showLabels || count === 0) return [];
  let edge = count - 1;
  if (edge === data.inProgress && edge > 0) edge -= 1;
  const placed: Array<{ key: string; name: string; mid: number; at: number; color: string }> = [];
  data.bands.forEach((band, index) => {
    const lower = y(stack.lower[index]?.[edge] ?? 0);
    const upper = y(stack.upper[index]?.[edge] ?? 0);
    if (lower - upper < 6) return;
    placed.push({
      key: band.key,
      name: usageModelDisplayName(band.model),
      mid: (lower + upper) / 2,
      at: 0,
      color: colorOf(band),
    });
  });
  placed.sort((left, right) => left.mid - right.mid);
  let last = -Infinity;
  for (const item of placed) {
    item.at = Math.max(item.mid + 4, last + 15);
    last = item.at;
  }
  return placed;
});

const arrival = $derived(annotate && !narrow && count > 2 ? riverArrival(data) : null);

const readout = $derived.by(() => {
  if (active === null) return null;
  const position = active;
  const rows = data.bands
    .map((band, index) => ({
      band,
      value:
        mode === "share"
          ? (stack.upper[index]?.[position] ?? 0) - (stack.lower[index]?.[position] ?? 0)
          : (band.values[position] ?? 0),
      unpriced: band.unpriced[position] ?? false,
    }))
    .filter((row) => row.value > 0 || row.unpriced)
    .sort((left, right) => right.value - left.value);
  return {
    title: position === data.inProgress ? "Today, so far" : dayLabel(position),
    rows,
  };
});

const readoutText = $derived(
  readout
    ? `${readout.title}: ${
        readout.rows.length === 0
          ? "no usage recorded"
          : readout.rows
              .map(
                (row) =>
                  `${usageModelDisplayName(row.band.model)} ${row.unpriced && row.value === 0 ? "unpriced" : mode === "share" ? `${Math.round(row.value * 100)}%` : format(row.value)}`,
              )
              .join(", ")
      }`
    : "",
);

let svgEl = $state<SVGSVGElement | null>(null);

function pointAt(event: PointerEvent): void {
  if (!svgEl || count === 0) return;
  const box = svgEl.getBoundingClientRect();
  const px = ((event.clientX - box.left) / box.width) * width;
  if (px < L - 4 || px > width - R + 4) {
    active = null;
    return;
  }
  active = count > 1 ? Math.max(0, Math.min(count - 1, Math.round((px - L) / step))) : 0;
}

function onKey(event: KeyboardEvent): void {
  if (count === 0) return;
  const current = active ?? count - 1;
  const next =
    event.key === "ArrowLeft"
      ? Math.max(0, current - 1)
      : event.key === "ArrowRight"
        ? Math.min(count - 1, current + 1)
        : event.key === "Home"
          ? 0
          : event.key === "End"
            ? count - 1
            : event.key === "Escape"
              ? null
              : undefined;
  if (next === undefined) return;
  event.preventDefault();
  active = next;
}

const tipLeft = $derived(active === null ? 0 : x(active));
</script>

<div class="river" class:focus={highlight !== null} bind:clientWidth={width}>
  <svg
    bind:this={svgEl}
    viewBox="0 0 {width} {height}"
    width={width}
    height={height}
    role="slider"
    aria-label={label}
    aria-valuemin={0}
    aria-valuemax={Math.max(0, count - 1)}
    aria-valuenow={active ?? Math.max(0, count - 1)}
    aria-valuetext={readoutText || "Use the arrow keys to read a day"}
    tabindex="0"
    onpointermove={pointAt}
    onpointerleave={() => {
      active = null;
      onHighlight?.(null);
    }}
    onkeydown={onKey}
    onfocus={() => {
      if (active === null && count > 0) active = count - 1;
    }}
    onblur={() => (active = null)}
  >
    <defs>
      <pattern id="{uid}-hatch" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
        <rect width="2.5" height="6" fill="var(--canvas)" opacity="0.7" />
      </pattern>
    </defs>
    {#each valueTicks as tick, index (index)}
      <line class="grid" x1={L} x2={width - R} y1={y(tick)} y2={y(tick)} />
      <text class="axis" x={L - 8} y={y(tick) + 4} text-anchor="end"
        >{mode === "share" ? `${Math.round(tick * 100)}%` : tick === 0 ? "0" : format(tick)}</text
      >
    {/each}
    {#each dateTicks as position (position)}
      <text
        class="axis"
        x={x(position)}
        y={height - 4}
        text-anchor={count === 1 ? "middle" : position === 0 ? "start" : position === count - 1 ? "end" : "middle"}
        >{dayLabel(position)}</text
      >
    {/each}
    {#each data.dates as date, position (date)}
      {#if !data.present[position]}
        <line class="empty-tick" x1={x(position) - 3} x2={x(position) + 3} y1={height - B} y2={height - B} />
      {/if}
    {/each}
    {#each data.bands as band, index (band.key)}
      <path
        class="band"
        class:on={highlight === band.key}
        d={bandPath(index)}
        fill={colorOf(band)}
        data-model={band.model}
        role="presentation"
        onpointerenter={() => onHighlight?.(band.key)}
      />
    {/each}
    {#if data.inProgress !== null && count > 1}
      <rect
        class="in-progress"
        x={x(data.inProgress) - step / 2}
        y={T}
        width={step / 2}
        height={height - B - T}
        fill="url(#{uid}-hatch)"
      />
    {/if}
    {#if arrival}
      <line class="arrival" x1={x(arrival.index)} x2={x(arrival.index)} y1={T - 6} y2={height - B} />
      <text
        class="annotation"
        x={x(arrival.index) + (x(arrival.index) + 240 > width ? -6 : 6)}
        y={T + 2}
        text-anchor={x(arrival.index) + 240 > width ? "end" : "start"}
        >{dayLabel(arrival.index)} · {arrival.model} arrives</text
      >
    {/if}
    {#each endLabels as item (item.key)}
      <path
        class="leader"
        d="M{width - R + 2},{item.mid} L{width - R + 10},{item.at - 4}"
        stroke={item.color}
      />
      <text class="end-label" x={width - R + 14} y={item.at}>{item.name}</text>
    {/each}
    {#if active !== null}
      <line class="crosshair" x1={x(active)} x2={x(active)} y1={T} y2={height - B} />
    {/if}
  </svg>
  {#if readout}
    <div
      class="tip"
      aria-hidden="true"
      style:left={tipLeft + 236 > width ? undefined : `${tipLeft + 12}px`}
      style:right={tipLeft + 236 > width ? `${width - tipLeft + 12}px` : undefined}
    >
      <b>{readout.title}</b>
      {#if readout.rows.length === 0}
        <span class="tip-empty">No usage recorded</span>
      {:else}
        {#each readout.rows as row (row.band.key)}
          <div class="tip-row">
            <i style:background={colorOf(row.band)}></i>
            <span class="tip-model" class:other={row.band.model === USAGE_OTHER_MODEL}
              >{usageModelDisplayName(row.band.model)}</span
            >
            <span class="tip-value"
              >{row.unpriced && row.value === 0
                ? "unpriced"
                : mode === "share"
                  ? `${Math.round(row.value * 100)}%`
                  : format(row.value)}</span
            >
          </div>
        {/each}
      {/if}
    </div>
  {/if}
</div>

<style>
.river {
  position: relative;
  min-width: 0;
}

svg {
  display: block;
  width: 100%;
  height: auto;
  overflow: visible;
  touch-action: pan-y;
}

svg:focus-visible {
  outline: 2px solid var(--brand);
  outline-offset: 4px;
  border-radius: 6px;
}

.grid {
  stroke: var(--hairline);
}

.axis {
  fill: var(--body);
  font: 11px var(--sans);
  font-variant-numeric: tabular-nums;
}

.empty-tick {
  stroke: var(--meter-track);
  stroke-width: 2;
}

.band {
  stroke: var(--canvas);
  stroke-width: 1;
  transition: opacity 0.12s;
}

.river.focus .band {
  opacity: 0.16;
}

.river.focus .band.on {
  opacity: 1;
}

.arrival {
  stroke: var(--ink);
  stroke-dasharray: 3 3;
  opacity: 0.45;
}

.annotation {
  fill: var(--ink);
  font: 600 11px var(--sans);
}

.leader {
  fill: none;
  stroke-width: 2;
}

.end-label {
  fill: var(--ink);
  font: 600 11.5px var(--mono);
}

.crosshair {
  stroke: var(--ink);
  opacity: 0.3;
}

.tip {
  position: absolute;
  top: 6px;
  z-index: 5;
  display: grid;
  gap: 3px;
  min-width: 210px;
  padding: 8px 10px;
  border: 1px solid var(--strong);
  border-radius: 10px;
  background: var(--canvas);
  font-size: 12px;
  pointer-events: none;
}

.tip-row {
  display: grid;
  grid-template-columns: 10px 1fr auto;
  gap: 8px;
  align-items: center;
}

.tip-row i {
  width: 8px;
  height: 8px;
  border-radius: 2px;
}

.tip-model {
  font-family: var(--mono);
  font-size: 11.5px;
}

.tip-model.other {
  font-family: var(--sans);
}

.tip-value,
.tip-empty {
  color: var(--body);
  font-variant-numeric: tabular-nums;
}

@media (prefers-reduced-motion: reduce) {
  .band {
    transition: none;
  }
}
</style>
