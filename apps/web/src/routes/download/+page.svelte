<script lang="ts">
import InstallOptions from "$lib/components/InstallOptions.svelte";
</script>

<svelte:head>
  <title>Download · Quota</title>
  <meta
    name="description"
    content="Download QuotaBar for macOS. Apple silicon, macOS 14 or later, with Homebrew and Sparkle updates."
  />
  <link rel="canonical" href="https://quota.gotry.io/download" />
</svelte:head>

<section class="document-page" aria-labelledby="page-title">
  <p class="eyebrow">QuotaBar</p>
  <h1 id="page-title">Download</h1>
  <p class="hero-summary">
    Install QuotaBar on a Mac with Apple silicon. It updates itself after that.
  </p>
  <InstallOptions />
  <div class="document-notes">
    <p>Requirements: macOS 14 or later, Apple silicon</p>
    <p>Updates: QuotaBar updates itself with Sparkle</p>
    <p>Quota for iPhone: coming soon</p>
  </div>
</section>
