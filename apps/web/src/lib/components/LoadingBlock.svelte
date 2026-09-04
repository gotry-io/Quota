<script lang="ts">
let {
  lines = 3,
  label = "Loading",
}: {
  lines?: number;
  label?: string;
} = $props();
</script>

<div class="loading-block" aria-busy="true" aria-label={label} role="status">
  {#each Array.from({ length: lines }, (_, index) => index) as index (index)}
    <div class="loading-block-line"></div>
  {/each}
</div>
