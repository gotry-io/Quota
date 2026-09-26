<script lang="ts">
import type { PublicProfile } from "@gotry-io/quota-protocol";
import {
  type AccountError,
  accountNoticeActionLabel,
  accountNoticeRetry,
} from "$lib/account-errors";
import LoadingBlock from "$lib/components/LoadingBlock.svelte";
import RetryNotice from "$lib/components/RetryNotice.svelte";
import { handleProblem } from "$lib/public-profile";
import { publicProfileUrl } from "$lib/routes";
import {
  fetchPublicProfile,
  HANDLE_TAKEN_COPY,
  savePublicProfile,
} from "$lib/public-profile-client";

let loading = $state(true);
let saving = $state(false);
let loadError = $state<AccountError | null>(null);
let problem = $state<string | null>(null);
let saved = $state(false);
let copied = $state(false);

let handle = $state("");
let enabled = $state(false);
let showModels = $state(true);
let showCost = $state(false);
let published = $state<string | null>(null);

/**
 * The page is configured from one read and written back whole.
 *
 * There is no partial update: the handle and the three switches are one statement about what
 * this Account publishes, and sending them together is what makes the answer Relay stores
 * the same thing the form shows.
 */
async function load(): Promise<void> {
  loading = true;
  loadError = null;
  const result = await fetchPublicProfile();
  loading = false;
  if (result.status === "error") {
    loadError = result.error;
    return;
  }
  if (result.status === "handle_taken") return;
  apply(result.profile);
}

function apply(profile: PublicProfile): void {
  handle = profile.handle ?? "";
  enabled = profile.enabled;
  showModels = profile.show_models;
  showCost = profile.show_cost;
  published = profile.enabled ? profile.handle : null;
}

async function save(): Promise<void> {
  const trimmed = handle.trim().toLowerCase();
  saved = false;
  copied = false;
  problem = handleProblem(trimmed);
  if (problem) return;
  saving = true;
  const result = await savePublicProfile({
    handle: trimmed,
    enabled,
    show_models: showModels,
    show_cost: showCost,
  });
  saving = false;
  if (result.status === "handle_taken") {
    problem = HANDLE_TAKEN_COPY;
    return;
  }
  if (result.status === "error") {
    loadError = result.error;
    return;
  }
  apply(result.profile);
  saved = true;
}

async function copyLink(): Promise<void> {
  if (!published) return;
  await navigator.clipboard.writeText(publicProfileUrl(published));
  copied = true;
}

$effect(() => {
  void load();
});
</script>

{#if loading}
  <LoadingBlock lines={3} label="Loading your public page" />
{:else}
  {#if loadError}
    <RetryNotice
      id="public-profile-error"
      message={loadError.message}
      actionLabel={accountNoticeActionLabel(loadError)}
      onRetry={accountNoticeRetry(loadError, () => void load())}
    />
  {/if}

  <div class="split-row">
    <div>
      <label class="split-row-title" for="public-profile-handle">Handle</label>
      <div class="split-row-detail" id="public-profile-handle-help">
        3 to 30 characters: lowercase letters, numbers, and hyphens.
      </div>
    </div>
    <span class="field">
      <span aria-hidden="true">quota.gotry.io/u/</span>
      <input
        id="public-profile-handle"
        type="text"
        autocomplete="off"
        spellcheck="false"
        maxlength="30"
        bind:value={handle}
        aria-describedby="public-profile-handle-help"
      />
    </span>
  </div>
  <label class="split-row">
    <span class="split-row-title">Publish this page</span>
    <input
      id="public-profile-enabled"
      class="switch"
      type="checkbox"
      role="switch"
      bind:checked={enabled}
    />
  </label>
  <label class="split-row">
    <span class="split-row-title">Show which models</span>
    <input
      id="public-profile-models"
      class="switch"
      type="checkbox"
      role="switch"
      bind:checked={showModels}
    />
  </label>
  <label class="split-row">
    <span class="split-row-title">Show API-equivalent cost</span>
    <input
      id="public-profile-cost"
      class="switch"
      type="checkbox"
      role="switch"
      bind:checked={showCost}
    />
  </label>

  <div class="split-row">
    <div class="split-row-actions">
      {#if published}
        <a class="pill" href="/u/{published}">Open page</a>
        <button class="pill" type="button" onclick={() => void copyLink()}>
          {copied ? "Copied" : "Copy link"}
        </button>
      {/if}
    </div>
    <button
      id="public-profile-save"
      class="pill primary"
      type="button"
      disabled={saving}
      onclick={() => void save()}>{saving ? "Saving…" : "Save"}</button
    >
  </div>
  <p class="split-note" role="status">
    {#if problem}
      <span id="public-profile-problem" class="split-problem">{problem}</span>
    {:else if saved && published}
      Published at {publicProfileUrl(published)}
    {:else if saved}
      Saved. This page is not published.
    {/if}
  </p>
{/if}
