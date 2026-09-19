<script lang="ts">
import {
  type UsageExportInput,
  usageExportCsv,
  usageExportFilename,
  usageExportJsonText,
} from "$lib/usage-export";

let { input }: { input: UsageExportInput | null } = $props();

let menu = $state<HTMLDetailsElement | null>(null);
const canExport = $derived(input !== null);

$effect(() => {
  const onPointerDown = (event: PointerEvent): void => {
    if (menu?.open && event.target instanceof Node && !menu.contains(event.target)) {
      menu.open = false;
    }
  };
  document.addEventListener("pointerdown", onPointerDown);
  return () => document.removeEventListener("pointerdown", onPointerDown);
});

function close(): void {
  if (menu) menu.open = false;
}

function download(format: "csv" | "json"): void {
  if (!input) return;
  const body = format === "csv" ? usageExportCsv(input) : usageExportJsonText(input);
  const type = format === "csv" ? "text/csv;charset=utf-8" : "application/json;charset=utf-8";
  const blob = new Blob([body], { type });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = usageExportFilename(input.from, input.to, format);
  document.body.append(anchor);
  anchor.click();
  anchor.remove();
  URL.revokeObjectURL(url);
  close();
}

function onSummaryClick(event: MouseEvent): void {
  if (canExport) return;
  event.preventDefault();
}
</script>

<details class="export-menu" bind:this={menu}>
  <summary
    class="export-menu-trigger"
    id="usage-export"
    aria-label="Export"
    aria-disabled={canExport ? undefined : "true"}
    title={canExport ? "Export this period" : "Export is available for a period with daily totals"}
    onclick={onSummaryClick}
  >
    Export
  </summary>
  {#if canExport}
    <div class="export-menu-popover" role="menu" aria-label="Export format">
      <button type="button" role="menuitem" onclick={() => download("csv")}>CSV</button>
      <button type="button" role="menuitem" onclick={() => download("json")}>JSON</button>
    </div>
  {/if}
</details>
