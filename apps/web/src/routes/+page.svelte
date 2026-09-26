<script lang="ts">
import BrewCommand from "$lib/components/BrewCommand.svelte";
import PageSection from "$lib/components/PageSection.svelte";
import ProviderMark from "$lib/components/ProviderMark.svelte";
import { IOS_AVAILABILITY, iosAvailabilityCopy, QUOTABAR_DMG_URL } from "$lib/platforms.ts";
import { AGENT_DISPLAY_NAMES, CATALOG_PROVIDERS } from "$lib/providers.ts";
import { signInHref } from "$lib/routes.ts";

const ios = iosAvailabilityCopy(IOS_AVAILABILITY);
const title = "Quota — Every model your agents use, and what's left on every plan";
const description =
  "QuotaBar reads your coding agents on the Mac. The web shows which models did the work and how much quota is left; credentials and prompts never leave the Mac.";
const named = CATALOG_PROVIDERS.slice(0, 3).map((provider) => provider.display_name);
const more = CATALOG_PROVIDERS.length - named.length;
</script>

<svelte:head>
  <title>{title}</title>
  <meta name="description" content={description} />
  <link rel="canonical" href="https://quota.gotry.io/" />
  <meta property="og:title" content={title} />
  <meta property="og:description" content={description} />
  <meta property="og:url" content="https://quota.gotry.io/" />
</svelte:head>

<section class="hero" aria-labelledby="hero-title">
  <h1 id="hero-title">
    Every model your agents use, <span>and what's left on every plan.</span>
  </h1>
  <p class="hero-summary">
    QuotaBar reads {named.join(", ")} and {more} more on your Mac. The web shows which models did the
    work and how much quota is left. Credentials and prompts never leave the Mac.
  </p>
  <div class="hero-actions">
    <a class="pill primary lg" href={QUOTABAR_DMG_URL}>Download for macOS</a>
    <a class="pill lg" href={signInHref()} data-sveltekit-reload>Sign in</a>
  </div>
  <p class="hero-facts">
    <span><b>{CATALOG_PROVIDERS.length}</b> providers</span>
    <span><b>{AGENT_DISPLAY_NAMES.length}</b> agents</span>
    <span>Free &amp; open source · MIT · macOS 14+</span>
  </p>
</section>

<div class="hero-preview">
  <figure class="preview-shot preview-web">
    <img
      class="shot-light"
      src="/screenshots/web-overview-light-desktop.png"
      width="1440"
      height="900"
      alt="Quota account overview with remaining-quota cards for Codex, Claude Code, and Grok"
    />
    <img
      class="shot-dark"
      src="/screenshots/web-overview-dark-desktop.png"
      width="1440"
      height="900"
      alt=""
    />
  </figure>
  <figure class="preview-shot preview-quotabar">
    <img
      class="shot-light"
      src="/screenshots/quotabar-overview-light.png"
      width="640"
      height="960"
      alt="QuotaBar menu bar showing remaining Codex Plus, Claude Code Max, and Grok SuperGrok quota"
    />
    <img
      class="shot-dark"
      src="/screenshots/quotabar-overview-dark.png"
      width="640"
      height="960"
      alt=""
    />
  </figure>
  <figure class="preview-shot preview-ios">
    <img
      class="shot-light"
      src="/screenshots/ios-overview-light.png"
      width="1206"
      height="2622"
      alt="Quota for iPhone overview showing remaining quota on Codex, Claude Code, and Grok"
    />
    <img
      class="shot-dark"
      src="/screenshots/ios-overview-dark.png"
      width="1206"
      height="2622"
      alt=""
    />
    <figcaption>Preview</figcaption>
  </figure>
</div>

<PageSection id="why-title" title="Why people keep it open">
  <ul class="points">
    <li><span><b>See which model did the work</b>, across every agent, with names merged.</span></li>
    <li class="point-brand"><span><b>Know what cache saved you</b>, in dollars, not only a percentage.</span></li>
    <li class="point-warn"><span><b>See a limit coming</b>, before it stops you.</span></li>
    <li><span><b>A calm weekly recap</b>, private until you share it.</span></li>
  </ul>
</PageSection>

<PageSection id="catalog-title" title="Providers & agents">
  {#snippet note()}From the provider catalog{/snippet}
  <ul class="provider-grid" aria-label="Providers">
    {#each CATALOG_PROVIDERS as provider (provider.id)}
      <li>
        <ProviderMark provider={provider.id} />
        {provider.display_name}
      </li>
    {/each}
  </ul>
  <ul class="tag-list" aria-label="Agents">
    {#each AGENT_DISPLAY_NAMES as name (name)}
      <li class="tag">{name}</li>
    {/each}
  </ul>
</PageSection>

<PageSection id="privacy-title" title="What never leaves your Mac">
  {#snippet note()}<a class="link" href="/privacy">Privacy →</a>{/snippet}
  <ul class="points">
    <li><span><b>Provider credentials.</b> Tokens, cookies, and keys are read in place.</span></li>
    <li><span><b>Prompts and paths.</b> Usage is counted from local logs; the text stays local.</span></li>
    <li class="point-brand"><span><b>Only totals sync:</b> remaining quota and Usage per model and hour.</span></li>
  </ul>
</PageSection>

<PageSection id="install-title" title="Install">
  {#snippet note()}Quota for iPhone: {ios.label}{/snippet}
  <div class="install-row">
    <a class="pill primary" href={QUOTABAR_DMG_URL}>Download .dmg</a>
    <div class="install-brew"><BrewCommand /></div>
    {#if ios.url && ios.actionLabel}
      <a class="pill" href={ios.url}>{ios.actionLabel}</a>
    {/if}
  </div>
</PageSection>

<style>
.hero {
  display: grid;
  justify-items: start;
  gap: 18px;
  padding: 64px 0 40px;
}

.hero h1 {
  max-width: 14em;
  margin: 0;
  font-family: var(--rounded);
  font-size: 52px;
  font-weight: 500;
  letter-spacing: -0.015em;
  line-height: 1.06;
  text-wrap: balance;
}

.hero h1 span {
  color: var(--body);
}

.hero-summary {
  max-width: 38rem;
  margin: 0;
  color: var(--body);
  font-size: 17px;
}

.hero-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}

.hero-facts {
  display: flex;
  flex-wrap: wrap;
  gap: 6px 22px;
  margin: 0;
  color: var(--body);
  font-size: 13px;
}

.hero-facts b {
  color: var(--ink);
  font-weight: 600;
}

.hero-preview {
  display: grid;
  grid-template-columns: 1.6fr 0.667fr 0.46fr;
  gap: 16px;
  align-items: start;
  margin-bottom: 48px;
}

.preview-shot {
  position: relative;
  min-width: 0;
  margin: 0;
}

.preview-shot img {
  display: block;
  width: 100%;
  height: auto;
  border: 1px solid var(--hairline);
  border-radius: 12px;
}

.preview-shot figcaption {
  margin-top: 6px;
  color: var(--body);
  font-size: 12px;
}

.preview-shot .shot-dark {
  display: none;
}

@media (prefers-color-scheme: dark) {
  :global(html:not([data-theme="light"])) .preview-shot .shot-light {
    display: none;
  }

  :global(html:not([data-theme="light"])) .preview-shot .shot-dark {
    display: block;
  }
}

:global(html[data-theme="dark"]) .preview-shot .shot-light {
  display: none;
}

:global(html[data-theme="dark"]) .preview-shot .shot-dark {
  display: block;
}

.points {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0 48px;
  margin: 0;
  padding: 0;
  list-style: none;
}

.points li {
  display: grid;
  grid-template-columns: 16px 1fr;
  gap: 8px;
  padding: 12px 0;
  border-bottom: 1px solid var(--hairline);
  color: var(--body);
  font-size: 15.5px;
}

.points li::before {
  content: "";
  width: 7px;
  height: 7px;
  margin-top: 9px;
  border-radius: 9999px;
  background: var(--ink);
}

.points li.point-brand::before {
  background: var(--brand);
}

.points li.point-warn::before {
  background: var(--quota-warning);
}

.points b {
  color: var(--ink);
  font-weight: 600;
}

.provider-grid {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 0 32px;
  margin: 0;
  padding: 0;
  list-style: none;
}

.provider-grid li {
  display: flex;
  gap: 10px;
  align-items: center;
  padding: 9px 0;
  border-bottom: 1px solid var(--hairline);
}

.provider-grid :global(.provider-mark),
.provider-grid :global(.provider-mark-fallback) {
  width: 22px;
  height: 22px;
}

.tag-list {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin: 0;
  padding: 0;
  list-style: none;
}

.install-row {
  display: flex;
  flex-wrap: wrap;
  gap: 12px;
  align-items: center;
}

.install-brew {
  flex: 1;
  min-width: 260px;
  max-width: 460px;
}

@media (max-width: 960px) {
  .points {
    grid-template-columns: 1fr;
  }

  .provider-grid {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
}

@media (max-width: 768px) {
  .hero {
    padding-top: 32px;
  }

  .hero h1 {
    font-size: 34px;
  }

  .hero-preview {
    grid-template-columns: 0.667fr 0.46fr;
  }

  .preview-web {
    grid-column: 1 / -1;
  }

  .install-brew {
    min-width: 0;
    flex-basis: 100%;
  }
}
</style>
