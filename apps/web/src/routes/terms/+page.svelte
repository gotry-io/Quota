<script lang="ts">
import terms from "../../content/terms.md?raw";
import MarkdownBody from "$lib/components/MarkdownBody.svelte";
</script>

<svelte:head>
  <title>Terms · Quota</title>
  <meta
    name="description"
    content="Draft terms for Quota, including the MIT license and the Apple Standard EULA for iOS."
  />
  <link rel="canonical" href="https://quota.gotry.io/terms" />
</svelte:head>

<MarkdownBody source={terms} draft />
