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

<div class="methods">
  {#if sent}
    <div class="email-sent" role="status">
      <h2>Check your email</h2>
      <p>A sign-in link is on its way. It expires in 15 minutes.</p>
      <button class="pill" type="button" onclick={onUseAnotherWay}>Use another way</button>
    </div>
  {:else}
    {#each offered.filter((provider) => provider !== "email") as provider (provider)}
      <a
        class="pill {provider === 'apple' ? 'apple' : 'primary'}"
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
    <div class="or" aria-hidden="true">or</div>
    <form
      class="email"
      method="post"
      action="/api/auth/email/start"
      onsubmit={(event) => {
        event.preventDefault();
        void onSendLink();
      }}
    >
      <label class="visually-hidden" for="sign-in-email">Email</label>
      <input
        id="sign-in-email"
        class="input"
        type="email"
        name="email"
        autocomplete="email"
        inputmode="email"
        maxlength="254"
        placeholder="you@example.com"
        required
        bind:value={email}
      />
      <button class="pill primary" type="submit" disabled={sending}>Send sign-in link</button>
    </form>
    {#if error}
      <p class="notice" role="alert">{error}</p>
    {/if}
  {/if}
</div>

<style>
.methods {
  display: grid;
  gap: 8px;
}

/*
 * Apple's own button: black with a white mark and label, and the white one on a dark canvas,
 * which is the pair Apple's guidelines allow. It does not follow the site's ink tokens, because
 * the mark and its background are Apple's to specify.
 */
.apple {
  border-color: light-dark(#000000, #ffffff);
  color: light-dark(#ffffff, #000000);
  background: light-dark(#000000, #ffffff);
}

.apple:hover {
  border-color: light-dark(#000000, #ffffff);
  color: light-dark(#ffffff, #000000);
  opacity: 0.88;
}

.apple-mark {
  width: 17px;
  height: 17px;
  /* The mark sits optically high against a cap-height label. */
  margin-block-start: -2px;
}

.or {
  display: grid;
  grid-template-columns: 1fr auto 1fr;
  gap: 12px;
  align-items: center;
  margin: 6px 0;
  color: var(--body);
  font-size: 12px;
}

.or::before,
.or::after {
  content: "";
  height: 1px;
  background: var(--hairline);
}

.email {
  display: flex;
  gap: 8px;
}

.email .input {
  flex: 1;
  min-width: 0;
  min-height: 44px;
}

.email .pill {
  width: auto;
  flex: none;
}

.email-sent {
  display: grid;
  justify-items: start;
  gap: 10px;
}

.email-sent h2 {
  margin: 0;
  font-family: var(--rounded);
  font-size: 19px;
  font-weight: 500;
}

.email-sent p {
  margin: 0;
  color: var(--body);
}

.email-sent .pill {
  width: auto;
}
</style>
