<script lang="ts">
import { DASHBOARD_PATH, DEVICES_PATH, SETTINGS_PATH, USAGE_PATH } from "$lib/routes";

let { currentPath }: { currentPath: string } = $props();

const items = [
  { href: DASHBOARD_PATH, label: "Overview" },
  { href: USAGE_PATH, label: "Usage" },
  { href: DEVICES_PATH, label: "Devices" },
  { href: SETTINGS_PATH, label: "Settings" },
] as const;
</script>

<nav class="account-nav" aria-label="Account">
  {#each items as item (item.href)}
    <a
      href={item.href}
      data-sveltekit-preload-data="hover"
      aria-current={currentPath === item.href ? "page" : undefined}>{item.label}</a
    >
  {/each}
</nav>
