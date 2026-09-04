<script lang="ts">
import type { Snippet } from "svelte";

const brewCommand = "brew install gotry-io/tap/quotabar";
const quotabarDmgUrl =
  "https://github.com/gotry-io/Quota/releases/latest/download/QuotaBar-macos-arm64.dmg";

let { children }: { children?: Snippet } = $props();

let copied = $state(false);
let copiedReset: ReturnType<typeof setTimeout> | undefined;

async function copyBrew(): Promise<void> {
  await navigator.clipboard.writeText(brewCommand);
  copied = true;
  clearTimeout(copiedReset);
  copiedReset = setTimeout(() => {
    copied = false;
  }, 1600);
}
</script>

<div class="hero-actions">
  <a class="button button-primary" href={quotabarDmgUrl}>Download QuotaBar .dmg</a>
  {@render children?.()}
</div>
<div class="install-panel">
  <div class="install-copy">
    <p class="install-label">Homebrew</p>
    <p class="install-note">Install or update QuotaBar from the tap.</p>
  </div>
  <div class="brew-row">
    <code id="brew-install">{brewCommand}</code>
    <button
      class="button button-secondary install-copy-button"
      type="button"
      onclick={() => void copyBrew()}
    >
      {copied ? "Copied" : "Copy"}
    </button>
    <span class="visually-hidden" aria-live="polite">{copied ? "Copied" : ""}</span>
  </div>
</div>
