<script lang="ts">
import "../app.css";
import { page } from "$app/state";
import Header from "$lib/components/Header.svelte";
import PublicPageHeader from "$lib/components/PublicPageHeader.svelte";
import ThemeToggle from "$lib/components/ThemeToggle.svelte";
import { isAccountShellPath, isPublicProfilePath } from "$lib/routes";
import type { LayoutProps } from "./$types";

let { data, children }: LayoutProps = $props();
const year = new Date().getFullYear();
// A published page is read by whoever follows the link, so its chrome says nothing about who
// is reading it.
const published = $derived(isPublicProfilePath(page.url.pathname));
// The account shell sets its own column so the quota band can run edge to edge above it.
const accountShell = $derived(data.viewer !== null && isAccountShellPath(page.url.pathname));
</script>

{#if published}
  <PublicPageHeader />
{:else}
  <Header viewer={data.viewer} />
{/if}
<main id="main" class:wrap={!accountShell}>
  {@render children()}
</main>
<footer class="site-footer">
  <div class="wrap site-footer-row">
    <span>© {year} GoTry IO · MIT</span>
    <nav aria-label="Footer">
      <a href="/download">Download</a>
      <a href="/support">Support</a>
      <a href="/privacy">Privacy</a>
      <a href="/terms">Terms</a>
      <a href="https://github.com/gotry-io/Quota">GitHub ↗</a>
      <a href="/my">Account</a>
    </nav>
    <ThemeToggle />
  </div>
</footer>
