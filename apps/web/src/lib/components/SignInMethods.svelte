<script lang="ts">
import { IDENTITY_PROVIDERS, identityProviderDisplayName } from "@gotry-io/quota-protocol";
import { requestEmailSignInLink } from "$lib/account-client";
import { identityStartHref } from "$lib/routes";

let { returnTo }: { returnTo: string } = $props();

/**
 * The channels this build can start a sign-in through.
 *
 * Relay answers a GitHub round trip it does not sign in through with 404, so that button is
 * only shown when GitHub is offered. Email is a form on this page rather than a navigation.
 */
const offered = IDENTITY_PROVIDERS.filter(
  (provider) => provider === "github" || provider === "email",
);

let email = $state("");
let sent = $state(false);
let sending = $state(false);
let error = $state<string | null>(null);

async function onSendLink(): Promise<void> {
  sending = true;
  error = null;
  try {
    const result = await requestEmailSignInLink({ email, returnTo });
    if (result === "accepted") {
      sent = true;
      return;
    }
    if (result === "invalid") {
      error = "Enter an email address.";
      return;
    }
    if (result === "rate_limited") {
      error = "Too many sign-in attempts. Wait a moment and try again.";
      return;
    }
    error = "Quota could not send a sign-in link. Refresh and try again.";
  } finally {
    sending = false;
  }
}

function onUseAnotherWay(): void {
  sent = false;
  error = null;
}
</script>

<div class="sign-in-methods">
  {#if sent}
    <div class="email-sent" role="status">
      <h2>Check your email</h2>
      <p>A sign-in link is on its way. It expires in 15 minutes.</p>
      <button class="button button-secondary" type="button" onclick={onUseAnotherWay}>
        Use another way
      </button>
    </div>
  {:else}
    {#each offered.filter((provider) => provider !== "email") as provider (provider)}
      <a
        class="button button-primary"
        data-provider={provider}
        href={identityStartHref(provider, returnTo)}
        data-sveltekit-reload
      >
        Continue with {identityProviderDisplayName(provider)}
      </a>
    {/each}
    <form
      class="email-sign-in"
      method="post"
      action="/api/auth/email/start"
      onsubmit={(event) => {
        event.preventDefault();
        void onSendLink();
      }}
    >
      <label class="email-label" for="sign-in-email">Email</label>
      <input
        id="sign-in-email"
        class="email-input"
        type="email"
        name="email"
        autocomplete="email"
        inputmode="email"
        maxlength="254"
        required
        bind:value={email}
      />
      <button class="button button-primary" type="submit" disabled={sending}>
        Send sign-in link
      </button>
    </form>
    {#if error}
      <p class="notice" role="alert">{error}</p>
    {/if}
  {/if}
</div>

<style>
.sign-in-methods {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
  margin-top: 1.5rem;
}

.sign-in-methods :global(.button) {
  justify-content: center;
  width: 100%;
}

.email-sign-in {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  margin-top: 0.5rem;
}

.email-label {
  color: var(--charcoal);
  font-size: 13px;
  font-weight: 600;
}

.email-input {
  width: 100%;
  min-height: 42px;
  padding: 8px 12px;
  border: 1px solid var(--hairline);
  border-radius: 8px;
  background: var(--surface-soft);
  color: var(--ink);
  font-family: inherit;
  font-size: 14px;
}

.email-input:focus {
  outline: 2px solid var(--focus-ring);
  outline-offset: 1px;
}

.email-sent h2 {
  margin: 0 0 0.5rem;
  font-size: 1.15rem;
  line-height: 1.3;
}

.email-sent p {
  margin: 0 0 1rem;
  color: var(--body);
  line-height: 1.5;
}
</style>
