<script lang="ts">
import { page } from "$app/state";
import { signOut } from "$lib/account-client";
import { viewerInitial } from "$lib/account-overview";
import AccountNav from "$lib/components/AccountNav.svelte";
import QuotaMark from "$lib/components/QuotaMark.svelte";
import {
  DEVICES_PATH,
  isAccountShellPath,
  PUBLIC_PAGE_SETTINGS_PATH,
  SETTINGS_PATH,
  SIGN_IN_PATH,
  signInHref,
} from "$lib/routes";
import type { WebDocumentViewer } from "$lib/server/document-port";

let { viewer }: { viewer: WebDocumentViewer | null } = $props();

let menu = $state<HTMLDetailsElement | null>(null);
let error = $state<string | null>(null);

const onAccountShell = $derived(viewer !== null && isAccountShellPath(page.url.pathname));
const onSignIn = $derived(page.url.pathname === SIGN_IN_PATH);
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

function onMenuKeydown(event: KeyboardEvent): void {
  if (event.key !== "Escape" || !menu?.open) return;
  menu.open = false;
  menu.querySelector("summary")?.focus();
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
  <div class="wrap site-header-row">
    <a class="brand" href="/" aria-label="Quota home">
      <QuotaMark size={24} />
      <span>Quota</span>
    </a>
    {#if onAccountShell}
      <AccountNav currentPath={page.url.pathname} />
    {:else}
      <nav class="nav" aria-label="Primary">
        <a href="/" aria-current={page.url.pathname === "/" ? "page" : undefined}>Product</a>
        <a href="/download" aria-current={page.url.pathname === "/download" ? "page" : undefined}
          >Download</a
        >
        <a href="/support" aria-current={page.url.pathname === "/support" ? "page" : undefined}
          >Support</a
        >
        <a href="https://github.com/gotry-io/Quota">GitHub ↗</a>
      </nav>
    {/if}
    <div class="site-header-actions">
      {#if viewer === null}
        {#if !onSignIn}
          <a class="pill" href={signInHref()} data-sveltekit-reload>Sign in</a>
        {/if}
      {:else}
        <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
        <details
          id="header-account-menu"
          class="account-menu"
          bind:this={menu}
          onkeydown={onMenuKeydown}
        >
          <summary class="account-menu-trigger" aria-label="Account menu for {viewer.displayLabel}">
            <span aria-hidden="true">{initial}</span>
          </summary>
          <div class="account-menu-popover">
            <p class="account-menu-who">Signed in as {viewer.displayLabel}</p>
            {#if !onAccountShell}
              <a href="/my" onclick={closeMenu}>Home</a>
            {/if}
            <a href={DEVICES_PATH} onclick={closeMenu}>Devices</a>
            <a href={SETTINGS_PATH} onclick={closeMenu}>Settings</a>
            <a href={PUBLIC_PAGE_SETTINGS_PATH} onclick={closeMenu}>Public page</a>
            <form action="/api/auth/logout" method="post" onsubmit={onLogout}>
              <button type="submit">Sign out</button>
            </form>
          </div>
        </details>
      {/if}
    </div>
  </div>
</header>
{#if error}
  <p class="wrap notice" role="alert">{error}</p>
{/if}

<style>
.account-menu {
  position: relative;
}

.account-menu-trigger {
  display: grid;
  place-items: center;
  width: 32px;
  height: 32px;
  border: 1px solid var(--hairline);
  border-radius: 9999px;
  background: var(--canvas);
  font-family: var(--rounded);
  font-size: 13px;
  font-weight: 600;
  cursor: pointer;
  list-style: none;
}

.account-menu-trigger::-webkit-details-marker {
  display: none;
}

.account-menu-trigger:hover,
.account-menu[open] .account-menu-trigger {
  border-color: var(--strong);
}

.account-menu-popover {
  position: absolute;
  top: calc(100% + 10px);
  right: 0;
  z-index: 40;
  display: grid;
  width: 220px;
  padding: 6px;
  border: 1px solid var(--strong);
  border-radius: 12px;
  background: var(--canvas);
}

.account-menu-who {
  margin: 0 0 4px;
  padding: 6px 10px 8px;
  border-bottom: 1px solid var(--hairline);
  color: var(--body);
  font-size: 12px;
  overflow-wrap: anywhere;
}

.account-menu-popover a,
.account-menu-popover button {
  display: block;
  width: 100%;
  padding: 8px 10px;
  border: 0;
  border-radius: 8px;
  background: none;
  font-size: 13px;
  text-align: left;
  text-decoration: none;
  cursor: pointer;
}

.account-menu-popover form {
  margin: 0;
}

.account-menu-popover a:hover,
.account-menu-popover button:hover {
  background: var(--hover);
}

@media (max-width: 768px) {
  .account-menu-trigger {
    width: 40px;
    height: 40px;
  }
}
</style>
