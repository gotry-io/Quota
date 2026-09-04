<script lang="ts">
import privacy from "../../content/privacy.md?raw";
import MarkdownBody from "$lib/components/MarkdownBody.svelte";
</script>

<svelte:head>
  <title>Privacy · Quota</title>
  <meta
    name="description"
    content="Draft privacy policy for Quota: what is collected, what is not, who processes it, retention, and deletion."
  />
  <link rel="canonical" href="https://quota.gotry.io/privacy" />
</svelte:head>

<MarkdownBody source={privacy} draft />
