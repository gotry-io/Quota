<script lang="ts">
import { BREW_INSTALL_COMMAND } from "$lib/platforms";

let copied = $state(false);
let copiedReset: ReturnType<typeof setTimeout> | undefined;

async function copyBrew(): Promise<void> {
  await navigator.clipboard.writeText(BREW_INSTALL_COMMAND);
  copied = true;
  clearTimeout(copiedReset);
  copiedReset = setTimeout(() => {
    copied = false;
  }, 1600);
}
</script>

<div class="brew-command">
  <code id="brew-install">{BREW_INSTALL_COMMAND}</code>
  <button class="pill sm" type="button" onclick={() => void copyBrew()}>
    {copied ? "Copied" : "Copy"}
  </button>
  <span class="visually-hidden" aria-live="polite">{copied ? "Copied" : ""}</span>
</div>

<style>
.brew-command {
  flex: 1 1 auto;
  display: flex;
  gap: 8px;
  align-items: center;
  min-width: 0;
  padding: 4px 4px 4px 14px;
  border: 1px solid var(--hairline);
  border-radius: 9999px;
  background: var(--surface-soft);
}

code {
  flex: 1;
  min-width: 0;
  overflow-x: auto;
  font-family: var(--mono);
  font-size: 12px;
  white-space: nowrap;
  scrollbar-width: none;
}
</style>
