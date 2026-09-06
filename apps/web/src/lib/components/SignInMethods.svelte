<script lang="ts">
import { IDENTITY_PROVIDERS, identityProviderDisplayName } from "@gotry-io/quota-protocol";
import { identityStartHref } from "$lib/routes";

let { returnTo }: { returnTo: string } = $props();

/**
 * The channels this build can start a sign-in through.
 *
 * Relay answers a channel it does not sign in through with 404, so the buttons are the ones it
 * offers rather than every channel an Account may hold.
 */
const offered = IDENTITY_PROVIDERS.filter(
  (provider) => provider === "github" || provider === "apple",
);
</script>

<div class="sign-in-methods">
  {#each offered as provider (provider)}
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
</style>
