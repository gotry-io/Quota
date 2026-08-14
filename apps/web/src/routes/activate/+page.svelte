<script lang="ts">
import { page } from "$app/state";
import { decideActivation } from "$lib/account-client";

let userCode = $state(page.url.searchParams.get("user_code") ?? "");
let status = $state<string | null>(null);
let disabled = $state(false);

async function submit(decision: "approve" | "deny"): Promise<void> {
  const outcome = await decideActivation(userCode, decision);
  if (outcome === "invalid") {
    status = "Enter the exact code shown by your Quota client.";
    return;
  }
  if (outcome === "reauth") return;
  if (outcome === "error") {
    status = "Quota could not update this authorization. Check the code and try again.";
    return;
  }
  disabled = true;
  status =
    decision === "approve"
      ? "Installation authorized. Return to your Quota client."
      : "Authorization denied. You can close this page.";
}
</script>

<section id="activate-view" class="activate" aria-labelledby="activate-title">
  <p class="eyebrow">Quota client login</p>
  <h1 id="activate-title">Authorize this installation.</h1>
  <p class="hero-summary">
    Confirm the code shown by the requesting client. This grants account read and current-device
    upload sessions; it does not share provider credentials.
  </p>
  <form
    id="activate-form"
    class="activate-form"
    onsubmit={(event) => {
      event.preventDefault();
      void submit("approve");
    }}
  >
    <label for="user-code">Verification code</label>
    <input
      id="user-code"
      name="user_code"
      autocomplete="one-time-code"
      maxlength="32"
      required
      bind:value={userCode}
      {disabled}
    />
    <div class="hero-actions">
      <button class="button button-primary" type="submit" value="approve" {disabled}
        >Authorize</button
      >
      <button
        class="button button-secondary"
        type="button"
        id="deny-activation"
        {disabled}
        onclick={() => void submit("deny")}>Deny</button
      >
    </div>
  </form>
  {#if status}
    <p id="activate-status" class="notice" role="status">{status}</p>
  {/if}
</section>
