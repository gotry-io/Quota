<script lang="ts">
import { page } from "$app/state";
import { signOut } from "$lib/account-client";
import { viewerInitial } from "$lib/account-overview";
import AccountNav from "$lib/components/AccountNav.svelte";
import { isAccountShellPath, SETTINGS_PATH, signInHref } from "$lib/routes";
import type { WebDocumentViewer } from "$lib/server/document-port";

let { viewer }: { viewer: WebDocumentViewer | null } = $props();

let menu = $state<HTMLDetailsElement | null>(null);
let error = $state<string | null>(null);

const onAccountShell = $derived(viewer !== null && isAccountShellPath(page.url.pathname));
const initial = $derived(viewerInitial(viewer?.displayLabel));

$effect(() => {
  const onPointerDown = (event: PointerEvent): void => {
    if (menu?.open && event.target instanceof Node && !menu.contains(event.target)) {
      menu.open = false;
    }
  };
  document.addEventListener("pointerdown", onPointerDown);
  return () => document.removeEventListener("pointerdown", onPointerDown);
});

function closeMenu(): void {
  if (menu) menu.open = false;
}

async function onLogout(event: SubmitEvent): Promise<void> {
  event.preventDefault();
  try {
    await signOut();
  } catch {
    error = "Quota could not sign out this browser session. Refresh and try again.";
  }
}
</script>

<header class="site-header">
  <a class="brand" href="/" aria-label="Quota home">
    <img class="brand-mark" src="/logo.svg" alt="" width="24" height="24" />
    <span>Quota</span>
  </a>
  {#if onAccountShell}
    <AccountNav currentPath={page.url.pathname} />
  {:else}
    <nav class="primary-nav" aria-label="Primary navigation">
      <a href="/#how-it-works">Product</a>
      <a href="https://github.com/gotry-io/Quota">GitHub</a>
    </nav>
  {/if}
  <div class="header-session">
    <a
      id="header-login"
      class="button button-primary header-action"
      href={signInHref()}
      hidden={viewer !== null}
      data-sveltekit-reload
    >
      Sign in with GitHub
    </a>
    <div id="header-account" class="header-account" hidden={viewer === null}>
      <details id="header-account-menu" class="account-menu" bind:this={menu}>
        <summary class="account-menu-trigger" aria-label="{viewer?.displayLabel ?? 'Account'} menu">
          <span class="account-avatar-fallback" aria-hidden="true">{initial}</span>
          <span id="header-account-name" class="header-account-name"
            >{viewer?.displayLabel ?? "Account"}</span
          >
        </summary>
        <div class="account-menu-popover">
          <a href={SETTINGS_PATH} onclick={closeMenu}>Settings</a>
          <form action="/api/auth/logout" method="post" onsubmit={onLogout}>
            <button class="text-button" type="submit">Sign out</button>
          </form>
        </div>
      </details>
    </div>
  </div>
</header>
{#if error}
  <p class="notice" role="alert">{error}</p>
{/if}
