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
const offered = IDENTITY_PROVIDERS.filter((provider) => provider === "github");
</script>

<div class="sign-in-methods">
  {#each offered as provider (provider)}
    <a
      class="button button-primary"
      data-provider={provider}
      href={identityStartHref(provider, returnTo)}
      data-sveltekit-reload
    >
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
</style>
