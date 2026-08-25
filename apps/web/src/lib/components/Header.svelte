<script lang="ts">
import { signOut } from "$lib/account-client";
import { signInHref } from "$lib/routes";
import type { WebDocumentViewer } from "$lib/server/document-port";

let { viewer }: { viewer: WebDocumentViewer | null } = $props();

let menu = $state<HTMLDetailsElement | null>(null);
let error = $state<string | null>(null);

$effect(() => {
  const onPointerDown = (event: PointerEvent): void => {
    if (menu?.open && event.target instanceof Node && !menu.contains(event.target)) {
      menu.open = false;
    }
  };
  document.addEventListener("pointerdown", onPointerDown);
  return () => document.removeEventListener("pointerdown", onPointerDown);
});

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
  <nav aria-label="Primary navigation">
    <a href="/#product">Product</a>
    <a href="https://github.com/gotry-io/Quota">GitHub</a>
    <div class="header-session">
      <a
        id="header-login"
        class="button button-primary header-action"
        href={signInHref()}
        hidden={viewer !== null}
        data-sveltekit-reload
      >
        Continue with GitHub
      </a>
      <div id="header-account" class="header-account" hidden={viewer === null}>
        <a id="header-account-name" class="header-account-name" href="/my"
          >{viewer?.displayLabel ?? "Account"}</a
        >
        <details id="header-account-menu" class="account-menu" bind:this={menu}>
          <summary class="account-menu-trigger" aria-label="Account menu"></summary>
          <div class="account-menu-popover">
            <form action="/api/auth/logout" method="post" onsubmit={onLogout}>
              <button class="text-button" type="submit">Sign out</button>
            </form>
          </div>
        </details>
      </div>
    </div>
  </nav>
</header>
{#if error}
  <p class="notice" role="alert">{error}</p>
{/if}
