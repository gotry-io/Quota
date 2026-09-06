<script lang="ts">
import "../app.css";
import { page } from "$app/state";
import Header from "$lib/components/Header.svelte";
import PublicPageHeader from "$lib/components/PublicPageHeader.svelte";
import ThemeToggle from "$lib/components/ThemeToggle.svelte";
import { isPublicProfilePath } from "$lib/routes";
import type { LayoutProps } from "./$types";

let { data, children }: LayoutProps = $props();
const year = new Date().getFullYear();
// A published page is read by whoever follows the link, so its chrome says nothing about who
// is reading it.
const published = $derived(isPublicProfilePath(page.url.pathname));
</script>

{#if published}
  <PublicPageHeader />
{:else}
  <Header viewer={data.viewer} />
{/if}
<main id="main">
  {@render children()}
</main>
<footer>
  <span>© {year} GoTry IO · MIT</span>
  <div class="footer-controls">
    <div class="footer-links">
      <a href="/download">Download</a>
      <a href="/support">Support</a>
      <a href="/privacy">Privacy</a>
      <a href="/terms">Terms</a>
      <a href="https://github.com/gotry-io/Quota">GitHub</a>
      <a href="/my">Account</a>
    </div>
    <ThemeToggle />
  </div>
</footer>
