<script lang="ts">
import { identityProviderDisplayName } from "@gotry-io/quota-protocol";
import { requestEmailSignInLink } from "$lib/account-client";
import { identityStartHref, SIGN_IN_METHOD_ORDER } from "$lib/routes";

let { returnTo }: { returnTo: string } = $props();

/** Apple, GitHub, then Email — Email is a form on this page rather than a navigation. */
const offered = SIGN_IN_METHOD_ORDER;

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
        class="button {provider === 'apple' ? 'button-apple' : 'button-primary'}"
        data-provider={provider}
        href={identityStartHref(provider, returnTo)}
        data-sveltekit-reload
      >
        {#if provider === "apple"}
          <!--
            Apple asks for its own mark on this button rather than a word or a substitute glyph, so
            it is drawn here and hidden from the accessibility tree: the link already says Apple.
          -->
          <svg class="apple-mark" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
            <path
              fill="currentColor"
              d="M17.05 20.28c-.98.95-2.05.8-3.08.35-1.09-.46-2.09-.48-3.24 0-1.44.62-2.2.44-3.06-.35C2.79 15.25 3.51 7.59 9.05 7.31c1.35.07 2.29.74 3.08.8 1.18-.24 2.31-.93 3.57-.84 1.51.12 2.65.72 3.4 1.8-3.12 1.87-2.38 5.98.48 7.13-.57 1.5-1.31 2.99-2.54 4.09zM12.03 7.25c-.15-2.23 1.66-4.07 3.74-4.25.29 2.58-2.34 4.5-3.74 4.25z"
            />
          </svg>
        {/if}
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

/*
 * Apple's own button: black with a white mark and label, and the white one on a dark canvas,
 * which is the pair Apple's guidelines allow. It does not follow the site's ink tokens, because
 * the mark and its background are Apple's to specify.
 */
.button-apple {
  gap: 8px;
  color: light-dark(#ffffff, #000000);
  background: light-dark(#000000, #ffffff);
}

.button-apple:hover {
  background: light-dark(#1a1a1a, #e6e6e6);
}

.apple-mark {
  width: 17px;
  height: 17px;
  /* The mark sits optically high against a cap-height label. */
  margin-block-start: -2px;
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
