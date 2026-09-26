<script lang="ts">
import support from "../../content/support.md?raw";
import MarkdownBody from "$lib/components/MarkdownBody.svelte";
import PageHeader from "$lib/components/PageHeader.svelte";
</script>

<svelte:head>
  <title>Support · Quota</title>
  <meta
    name="description"
    content="Quota FAQ: where data comes from, iPhone, diagnostics, account deletion, and how to reach support."
  />
  <link rel="canonical" href="https://quota.gotry.io/support" />
</svelte:head>

<PageHeader>
  {#snippet eyebrow()}Support{/snippet}
  <b>Support.</b> Where the numbers come from, the iPhone app, diagnostics, and deleting an Account.
</PageHeader>

<MarkdownBody source={support} />
