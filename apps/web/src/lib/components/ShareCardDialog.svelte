<script lang="ts">
import type { PublicUsageResponse } from "@gotry-io/quota-protocol";
import { publicProfileUrl } from "$lib/routes";
import {
  drawShareCard,
  SHARE_CARD_HEIGHT,
  SHARE_CARD_WIDTH,
  shareCardFilename,
  shareCardModel,
} from "$lib/share-card";

let { profile }: { profile: PublicUsageResponse } = $props();

let dialog = $state<HTMLDialogElement | null>(null);
let canvas = $state<HTMLCanvasElement | null>(null);
let copied = $state(false);
const model = $derived(shareCardModel(profile));

$effect(() => {
  const target = canvas;
  if (target) drawShareCard(target, model);
});

function openDialog(): void {
  dialog?.showModal();
}

function closeDialog(): void {
  copied = false;
  dialog?.close();
}

async function copyLink(): Promise<void> {
  await navigator.clipboard.writeText(publicProfileUrl(profile.handle));
  copied = true;
}

/**
 * Hand the picture to the browser as a file.
 *
 * The card is drawn in the page rather than rendered on a server, so saving it is the canvas'
 * own bytes through one object URL that is released as soon as the click is taken.
 */
function saveImage(): void {
  canvas?.toBlob((blob) => {
    if (!blob) return;
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = shareCardFilename(profile.handle);
    link.click();
    URL.revokeObjectURL(url);
  }, "image/png");
}
</script>

<button id="share-profile" class="pill" type="button" onclick={openDialog}>Share</button>

<dialog bind:this={dialog} class="share-dialog" aria-labelledby="share-dialog-title">
  <div class="share-dialog-body">
    <h2 id="share-dialog-title">Share this page</h2>
    <canvas
      bind:this={canvas}
      class="share-card-canvas"
      width={SHARE_CARD_WIDTH}
      height={SHARE_CARD_HEIGHT}
      aria-label="Share card preview for {profile.handle}"
    ></canvas>
    <p class="share-dialog-url">{publicProfileUrl(profile.handle)}</p>
    <div class="share-dialog-actions">
      <button class="pill primary" type="button" onclick={saveImage}>Save image</button>
      <button class="pill" type="button" onclick={() => void copyLink()}>
        {copied ? "Copied" : "Copy link"}
      </button>
      <button class="pill" type="button" onclick={closeDialog}>Close</button>
    </div>
    <p class="share-dialog-note" role="status">
      {copied ? "Link copied to the clipboard." : ""}
    </p>
  </div>
</dialog>

<style>
.share-dialog {
  width: min(640px, calc(100vw - 32px));
  max-width: none;
  padding: 0;
  border: 1px solid var(--strong);
  border-radius: 16px;
  background: var(--canvas);
  color: var(--ink);
}

.share-dialog::backdrop {
  background: color-mix(in srgb, var(--canvas) 70%, transparent);
}

.share-dialog-body {
  display: grid;
  gap: 12px;
  padding: 20px;
}

.share-dialog-body h2 {
  margin: 0;
  font-family: var(--rounded);
  font-size: 18px;
  font-weight: 500;
}

.share-card-canvas {
  width: 100%;
  height: auto;
  border: 1px solid var(--hairline);
  border-radius: 12px;
}

.share-dialog-url,
.share-dialog-note {
  min-height: 1em;
  margin: 0;
  color: var(--body);
  font-size: 13px;
  overflow-wrap: anywhere;
}

.share-dialog-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  justify-content: flex-end;
}
</style>
