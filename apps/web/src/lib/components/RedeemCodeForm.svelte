<script lang="ts">
import { redeemCode } from "$lib/account-client";
import type { AccountError } from "$lib/account-errors";
import { REDEEM_ERROR_COPY, redeemGrantedCopy } from "$lib/account-overview";

let {
  onGranted,
  onError,
}: {
  onGranted: () => Promise<void>;
  onError: (error: AccountError) => void;
} = $props();

let code = $state("");
let redeeming = $state(false);
let redeemError = $state<string | null>(null);
let redeemSuccess = $state<string | null>(null);

async function onSubmit(event: SubmitEvent): Promise<void> {
  event.preventDefault();
  redeeming = true;
  redeemError = null;
  redeemSuccess = null;
  try {
    const result = await redeemCode(code);
    if (result.status === "ok") {
      redeemSuccess = redeemGrantedCopy(result.duration, result.campaign);
      await onGranted();
      return;
    }
    if (result.status === "error") {
      redeemError = REDEEM_ERROR_COPY[result.code];
      return;
    }
    onError(result);
  } finally {
    redeeming = false;
  }
}
</script>

<form
  class="redeem-form"
  method="post"
  action="/api/v2/account/redeem"
  onsubmit={onSubmit}
>
  <label class="visually-hidden" for="redeem-code">Redemption code</label>
  <input
    id="redeem-code"
    class="redeem-input"
    type="text"
    name="code"
    placeholder="QUOTA-XXXX-XXXX-XXXX-XXXX"
    autocapitalize="characters"
    autocomplete="off"
    spellcheck="false"
    maxlength="64"
    required
    bind:value={code}
  />
  <button class="button button-secondary" type="submit" disabled={redeeming}>Redeem</button>
</form>
{#if redeemError}
  <p class="notice" role="alert">{redeemError}</p>
{/if}
{#if redeemSuccess}
  <p class="notice" role="status">{redeemSuccess}</p>
{/if}

<style>
.redeem-form {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 12px;
  margin-top: 16px;
}

.redeem-input {
  flex: 1 1 16rem;
  min-width: 0;
  min-height: 42px;
  padding: 8px 12px;
  border: 1px solid var(--hairline);
  border-radius: 8px;
  background: var(--surface-soft);
  color: var(--ink);
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 13px;
}

.redeem-input:focus {
  outline: 3px solid var(--focus-ring);
  outline-offset: 1px;
}

.redeem-form + .notice {
  margin-top: 12px;
  margin-bottom: 0;
}

@media (max-width: 620px) {
  .redeem-form .button {
    width: 100%;
  }
}
</style>
