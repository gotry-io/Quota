<script lang="ts">
import terms from "../../content/terms.md?raw";
import MarkdownBody from "$lib/components/MarkdownBody.svelte";
import PageHeader from "$lib/components/PageHeader.svelte";
</script>

<svelte:head>
  <title>Terms · Quota</title>
  <meta
    name="description"
    content="Draft terms for Quota, including the MIT license and the Apple Standard EULA for iOS."
  />
  <link rel="canonical" href="https://quota.gotry.io/terms" />
</svelte:head>

<PageHeader>
  {#snippet eyebrow()}Terms <span class="tag">Draft</span>{/snippet}
  <b>Terms.</b> The terms for using Quota, QuotaBar, and QuotaRelay.
</PageHeader>

<MarkdownBody source={terms} />
