<script lang="ts">
import BrewCommand from "$lib/components/BrewCommand.svelte";
import PageHeader from "$lib/components/PageHeader.svelte";
import SplitSection from "$lib/components/SplitSection.svelte";
import { IOS_AVAILABILITY, iosAvailabilityCopy, QUOTABAR_DMG_URL } from "$lib/platforms";

const ios = iosAvailabilityCopy(IOS_AVAILABILITY);
</script>

<svelte:head>
  <title>Download · Quota</title>
  <meta
    name="description"
    content="Download QuotaBar for macOS. Apple silicon, macOS 14 or later, with Homebrew and Sparkle updates."
  />
  <link rel="canonical" href="https://quota.gotry.io/download" />
</svelte:head>

<PageHeader>
  {#snippet eyebrow()}Download{/snippet}
  <b>QuotaBar</b> for macOS 14 or later, on Apple silicon. It updates itself.
</PageHeader>

<SplitSection id="dmg-title" title="Disk image" description="Signed and notarized.">
  <div class="split-row">
    <div>
      <div class="split-row-title">QuotaBar-macos-arm64.dmg</div>
      <div class="split-row-detail">The latest release. Sparkle keeps it current after that.</div>
    </div>
    <a class="pill primary" href={QUOTABAR_DMG_URL}>Download .dmg</a>
  </div>
</SplitSection>

<SplitSection id="brew-title" title="Homebrew" description="Adds the gotry-io tap the first time.">
  <div class="split-row">
    <BrewCommand />
  </div>
</SplitSection>

<SplitSection id="iphone-title" title="iPhone" description="Reads the same Account.">
  <div class="split-row">
    <div>
      <div class="split-row-title">Quota for iPhone</div>
      <div class="split-row-detail">{ios.summary}</div>
    </div>
    {#if ios.url && ios.actionLabel}
      <a class="pill" href={ios.url}>{ios.actionLabel}</a>
    {:else}
      <span class="tag">{ios.label}</span>
    {/if}
  </div>
</SplitSection>
