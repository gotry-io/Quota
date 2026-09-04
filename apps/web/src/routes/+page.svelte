<script lang="ts">
import InstallOptions from "$lib/components/InstallOptions.svelte";
import ProviderMark from "$lib/components/ProviderMark.svelte";
import { IOS_AVAILABILITY, iosAvailabilityCopy } from "$lib/platforms.ts";
import { AGENT_DISPLAY_NAMES, CATALOG_PROVIDERS } from "$lib/providers.ts";
import { signInHref } from "$lib/routes.ts";

const dmgUrl =
  "https://github.com/gotry-io/Quota/releases/latest/download/QuotaBar-macos-arm64.dmg";
const ios = iosAvailabilityCopy(IOS_AVAILABILITY);
</script>

<svelte:head>
  <title>Quota — See what's left across your coding-agent plans</title>
  <meta
    name="description"
    content="QuotaBar reads your providers on the Mac; Relay syncs only remaining quota and Usage totals to the web."
  />
  <link rel="canonical" href="https://quota.gotry.io/" />
  <meta property="og:title" content="Quota — See what's left across your coding-agent plans" />
  <meta
    property="og:description"
    content="QuotaBar reads your providers on the Mac; Relay syncs only remaining quota and Usage totals to the web."
  />
  <meta property="og:url" content="https://quota.gotry.io/" />
</svelte:head>

<div id="landing-view">
  <section class="hero" aria-labelledby="hero-title">
    <div class="hero-copy">
      <h1 id="hero-title">See what's left across your coding-agent plans.</h1>
      <p class="hero-summary">
        QuotaBar reads your providers on the Mac; Relay syncs only remaining quota and Usage totals
        to the web.
      </p>
      <div class="hero-cta">
        <div class="hero-actions">
          <a class="button button-primary" href={dmgUrl}>Download for macOS</a>
          <a class="button button-secondary" href={signInHref()} data-sveltekit-reload
            >Sign in with GitHub</a
          >
        </div>
        <p class="hero-meta">Free &amp; open source · MIT · macOS 14+</p>
      </div>
    </div>

    <div class="hero-preview">
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
        <figcaption class="preview-caption">Preview</figcaption>
      </figure>
    </div>
  </section>

  <section class="landing-section" id="how-it-works" aria-labelledby="how-title">
    <div class="section-heading">
      <h2 id="how-title">How it works</h2>
    </div>
    <div class="how-grid">
      <article>
        <h3>Install QuotaBar</h3>
        <p>Download the macOS app and keep remaining quota in the menu bar.</p>
      </article>
      <article>
        <h3>It reads your providers locally</h3>
        <p>QuotaBar reads provider sessions and agent logs on your Mac. Credentials never upload.</p>
      </article>
      <article>
        <h3>The web shows the same numbers</h3>
        <p>Sign in to see remaining quota, Usage, and Devices in the browser.</p>
      </article>
    </div>
  </section>

  <section class="landing-section" aria-labelledby="catalog-title">
    <div class="section-heading">
      <h2 id="catalog-title">Providers &amp; agents</h2>
    </div>
    <div class="catalog-grid">
      <div>
        <h3>Providers</h3>
        <ul class="name-list">
          {#each CATALOG_PROVIDERS as provider (provider.id)}
            <li>
              <ProviderMark provider={provider.id} />
              {provider.display_name}
            </li>
          {/each}
        </ul>
      </div>
      <div>
        <h3>Agents</h3>
        <ul class="name-list">
          {#each AGENT_DISPLAY_NAMES as name (name)}
            <li>{name}</li>
          {/each}
        </ul>
      </div>
    </div>
  </section>

  <section class="privacy-callout" aria-labelledby="privacy-title">
    <h2 id="privacy-title">What never leaves your Mac</h2>
    <ul class="privacy-points">
      <li>Provider credentials, prompts, and local paths never leave your Mac.</li>
      <li>Quota uploads remaining quota and privacy-preserving Usage totals only.</li>
      <li>
        <a class="text-link" href="/privacy">Privacy</a> states what Relay keeps and how to delete it.
      </li>
    </ul>
  </section>

  <section class="landing-section" id="platforms" aria-labelledby="platforms-title">
    <div class="section-heading">
      <h2 id="platforms-title">Platforms</h2>
    </div>
    <div class="platforms-grid">
      <article class="platform-card">
        <p class="eyebrow">macOS</p>
        <h3>QuotaBar</h3>
        <p>Remaining quota in the menu bar. Apple silicon, macOS 14 or later.</p>
        <InstallOptions />
      </article>
      <article class="platform-card">
        <p class="eyebrow">Web</p>
        <h3>Account</h3>
        <p>The same remaining quota, Usage, and Devices in the browser.</p>
        <a class="button button-secondary" href={signInHref()} data-sveltekit-reload
          >Sign in with GitHub</a
        >
      </article>
      <article class="platform-card">
        <p class="eyebrow">iPhone</p>
        <h3>Quota</h3>
        <p class="platform-badge">{ios.label}</p>
        <p>{ios.summary}</p>
        {#if ios.url && ios.actionLabel}
          <a class="button button-secondary" href={ios.url}>{ios.actionLabel}</a>
        {/if}
      </article>
    </div>
  </section>
</div>
