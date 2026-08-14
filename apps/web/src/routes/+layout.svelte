<script lang="ts">
import "../app.css";
import Header from "$lib/components/Header.svelte";
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
  <span>© {year} gotry-io contributors · MIT</span>
  <div class="footer-links">
    <a href="https://github.com/gotry-io/Quota">GitHub</a>
    <a href="/my">Account</a>
  </div>
</footer>
