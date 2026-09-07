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
let onLeaderboard = $state(false);
let published = $state<string | null>(null);

/**
 * The page is configured from one read and written back whole.
 *
 * There is no partial update: the four values are one statement about what this Account
 * publishes, and sending them together is what makes the answer Relay stores the same thing
 * the form shows.
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
  onLeaderboard = profile.on_leaderboard;
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
    // A page that is not published has nowhere to be listed from, so switching it off takes
    // the row off the board rather than leaving a link nobody can follow.
    on_leaderboard: enabled && onLeaderboard,
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

<section class="settings-group" aria-labelledby="public-profile-title">
  <h2 id="public-profile-title">Public profile</h2>
  <p class="settings-note">
    Publish a read-only page of your Usage totals at
    <code>quota.gotry.io/u/&lt;handle&gt;</code>. Remaining quota, devices, providers, and your
    account stay private.
  </p>

  {#if loading}
    <LoadingBlock lines={3} label="Loading your public profile" />
  {:else}
    {#if loadError}
      <RetryNotice
        id="public-profile-error"
        message={loadError.message}
        actionLabel={accountNoticeActionLabel(loadError)}
        onRetry={accountNoticeRetry(loadError, () => void load())}
      />
    {/if}

    <div class="settings-row settings-field">
      <label for="public-profile-handle">Handle</label>
      <div class="handle-field">
        <span class="handle-prefix" aria-hidden="true">quota.gotry.io/u/</span>
        <input
          id="public-profile-handle"
          type="text"
          autocomplete="off"
          spellcheck="false"
          maxlength="30"
          bind:value={handle}
          aria-describedby="public-profile-handle-help"
        />
      </div>
    </div>
    <p id="public-profile-handle-help" class="settings-note">
      3 to 30 characters: lowercase letters, numbers, and hyphens.
    </p>

    <div class="settings-row">
      <label for="public-profile-enabled">Publish this page</label>
      <input id="public-profile-enabled" type="checkbox" bind:checked={enabled} />
    </div>
    <div class="settings-row">
      <label for="public-profile-models">Show which models</label>
      <input id="public-profile-models" type="checkbox" bind:checked={showModels} />
    </div>
    <div class="settings-row">
      <label for="public-profile-cost">Show API-equivalent cost</label>
      <input id="public-profile-cost" type="checkbox" bind:checked={showCost} />
    </div>
    <div class="settings-row">
      <label for="public-profile-leaderboard">Show on the leaderboard</label>
      <input
        id="public-profile-leaderboard"
        type="checkbox"
        bind:checked={onLeaderboard}
        disabled={!enabled}
        aria-describedby="public-profile-leaderboard-help"
      />
    </div>
    <p id="public-profile-leaderboard-help" class="settings-note">
      Ranks your handle and 30-day token total at <code>quota.gotry.io/leaderboard</code>. Off
      until you ask for it, and only while this page is published.
    </p>

    <div class="settings-actions">
      <button
        id="public-profile-save"
        class="button button-primary"
        type="button"
        disabled={saving}
        onclick={() => void save()}>{saving ? "Saving…" : "Save"}</button
      >
      {#if published}
        <a class="button" href="/u/{published}">Open page</a>
        <button class="text-button" type="button" onclick={() => void copyLink()}>
          {copied ? "Copied" : "Copy link"}
        </button>
      {/if}
    </div>
    <p class="settings-note" role="status">
      {#if problem}
        <span id="public-profile-problem" class="settings-problem">{problem}</span>
      {:else if saved && published}
        Published at {publicProfileUrl(published)}
      {:else if saved}
        Saved. This page is not published.
      {/if}
    </p>
  {/if}
</section>
