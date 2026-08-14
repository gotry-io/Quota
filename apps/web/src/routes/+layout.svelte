<script lang="ts">
import "../app.css";
import Header from "$lib/components/Header.svelte";
import ThemeToggle from "$lib/components/ThemeToggle.svelte";
import type { LayoutProps } from "./$types";

let { data, children }: LayoutProps = $props();
const year = new Date().getFullYear();
</script>

<svelte:head>
  <title>Quota — Know what you have left</title>
</svelte:head>

<Header viewer={data.viewer} />
<main id="main">
  {@render children()}
</main>
<footer>
  <span>© {year} GoTry IO · MIT</span>
  <div class="footer-controls">
    <div class="footer-links">
      <a href="https://github.com/gotry-io/Quota">GitHub</a>
      <a href="/my">Account</a>
    </div>
    <ThemeToggle />
  </div>
</footer>
