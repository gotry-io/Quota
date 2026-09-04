<script lang="ts">
import support from "../../content/support.md?raw";
import MarkdownBody from "$lib/components/MarkdownBody.svelte";
</script>

<svelte:head>
  <title>Support · Quota</title>
  <meta
    name="description"
    content="Quota FAQ: where data comes from, iPhone, diagnostics, account deletion, and how to reach support."
  />
  <link rel="canonical" href="https://quota.gotry.io/support" />
</svelte:head>

<MarkdownBody source={support} />
