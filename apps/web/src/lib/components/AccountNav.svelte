<script lang="ts">
import { accountNavPath, DASHBOARD_PATH, MODELS_PATH, QUOTA_PATH, RECAP_PATH } from "$lib/routes";

let { currentPath }: { currentPath: string } = $props();

const items = [
  { href: DASHBOARD_PATH, label: "Home" },
  { href: MODELS_PATH, label: "Models" },
  { href: QUOTA_PATH, label: "Quota" },
  { href: RECAP_PATH, label: "Recap" },
] as const;

const current = $derived(accountNavPath(currentPath));
</script>

<nav class="nav" aria-label="Account">
  {#each items as item (item.href)}
    <a
      href={item.href}
      data-sveltekit-preload-data="hover"
      aria-current={current === item.href ? "page" : undefined}>{item.label}</a
    >
  {/each}
</nav>

