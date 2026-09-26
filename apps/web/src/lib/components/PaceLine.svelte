<script lang="ts">
/**
 * A window's own samples under its meter ([`docs/design.md`](../../../../../docs/design.md),
 * Pace line): solid over the Account's readings inside the running window, dashed from the last
 * of them to where ADR 0035's projection lands at the reset. The vertical axis is the whole
 * window, 0–100 percent used; the horizontal axis is the window's start to its reset. It says
 * nothing the pace sentence does not, so it is hidden from assistive technology.
 */
let {
  points,
  start,
  end,
  now,
  used,
  projected,
  color,
}: {
  /** Used percent at instants inside the window, oldest first. */
  points: ReadonlyArray<{ at: number; used: number }>;
  start: number;
  end: number;
  now: number;
  /** The reading's used percent now. */
  used: number;
  /** Used percent the current rate reaches at the reset (may exceed 100). */
  projected: number;
  color: string;
} = $props();

const W = 600;
const H = 40;

function x(at: number): number {
  return ((Math.min(Math.max(at, start), end) - start) / (end - start)) * W;
}

function y(value: number): number {
  return H - 2 - (Math.min(Math.max(value, 0), 100) / 100) * (H - 6);
}

const solid = $derived(
  [...points, { at: now, used }]
    .filter((point) => point.at >= start && point.at <= now)
    .map((point) => `${x(point.at).toFixed(1)},${y(point.used).toFixed(1)}`)
    .join(" "),
);
/** Where the dashed estimate ends: the reset, or earlier where it crosses 100 percent. */
const projection = $derived.by(() => {
  if (projected <= 100) return { x: W, y: y(projected) };
  const fraction = projected > used ? (100 - used) / (projected - used) : 1;
  return { x: x(now) + fraction * (W - x(now)), y: y(100) };
});
</script>

<svg class="pace" viewBox="0 0 {W} {H}" preserveAspectRatio="none" aria-hidden="true">
  <line class="axis" x1="0" x2={W} y1={H - 2} y2={H - 2} />
  <line class="axis end" x1={W} x2={W} y1="2" y2={H - 2} />
  <polyline points={solid} fill="none" stroke={color} stroke-width="1.75" vector-effect="non-scaling-stroke" />
  <line
    x1={x(now)}
    y1={y(used)}
    x2={projection.x}
    y2={projection.y}
    stroke={color}
    stroke-width="1.5"
    stroke-dasharray="4 4"
    vector-effect="non-scaling-stroke"
  />
</svg>

<style>
.pace {
  display: block;
  width: 100%;
  height: 40px;
  margin-top: 6px;
  overflow: visible;
}

.axis {
  stroke: var(--hairline);
}

.axis.end {
  stroke-dasharray: 2 3;
}
</style>
