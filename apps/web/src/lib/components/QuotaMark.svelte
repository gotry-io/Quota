<script lang="ts">
/**
 * The Quota mark drawn inline, so its two greens follow the appearance: `static/logo.svg` is the
 * same geometry with fixed colours for places a stylesheet cannot reach.
 */
let { size = 24 }: { size?: number } = $props();
const uid = $props.id();
const mask = `quota-mark-${uid}`;
</script>

<svg class="quota-mark" viewBox="0 0 64 64" width={size} height={size} aria-hidden="true">
  <defs>
    <mask id={mask} maskUnits="userSpaceOnUse" x="0" y="0" width="64" height="64">
      <rect width="64" height="64" fill="#fff" />
      <circle cx="47.81" cy="47.81" r="5.28" fill="#000" />
    </mask>
  </defs>
  <circle
    class="quota-mark-outer"
    cx="32"
    cy="32"
    r="22.37"
    fill="none"
    stroke-width="4.97"
    mask="url(#{mask})"
  />
  <path
    class="quota-mark-inner"
    d="M36.57 44.55A13.36 13.36 0 1 1 44.55 36.57"
    fill="none"
    stroke-width="6.83"
    stroke-linecap="round"
  />
  <circle class="quota-mark-node" cx="47.81" cy="47.81" r="3.11" />
</svg>

<style>
.quota-mark {
  display: block;
  flex: none;
}

.quota-mark-outer {
  stroke: var(--activity-3);
}

.quota-mark-inner {
  stroke: var(--brand-emerald);
}

.quota-mark-node {
  fill: var(--brand-emerald);
}
</style>
