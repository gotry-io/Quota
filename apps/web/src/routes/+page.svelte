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
  <title>Quota — See what's left on every coding-agent plan</title>
  <meta
    name="description"
    content="See what's left on every coding-agent plan — Codex, Claude, Grok, Cursor — in your Mac menu bar, on the web, and on iPhone."
  />
  <link rel="canonical" href="https://quota.gotry.io/" />
  <meta property="og:title" content="Quota — See what's left on every coding-agent plan" />
  <meta
    property="og:description"
    content="See remaining quota for Codex, Claude, Grok, Cursor, and API keys in the menu bar, on the web, and on iPhone."
  />
  <meta property="og:url" content="https://quota.gotry.io/" />
</svelte:head>

<div id="landing-view">
  <section class="hero" aria-labelledby="hero-title">
    <div class="hero-copy">
      <h1 id="hero-title">
        See what's left on every coding-agent plan — Codex, Claude, Grok, Cursor — in your Mac menu
        bar, on the web, and on iPhone.
      </h1>
      <div class="hero-actions">
        <a class="button button-primary" href={dmgUrl}>Download for macOS</a>
        <a class="button button-secondary" href={signInHref()} data-sveltekit-reload
          >Sign in with GitHub</a
        >
      </div>
    </div>

    <div class="hero-preview">
      <figure class="preview-shot preview-quotabar">
        <picture>
          <source
            srcset="/screenshots/quotabar-overview-dark.png"
            media="(prefers-color-scheme: dark)"
            width="640"
            height="960"
          />
          <img
            src="/screenshots/quotabar-overview-light.png"
            width="640"
            height="960"
            alt="QuotaBar menu bar showing remaining Codex Plus, Claude Code Max, and Grok SuperGrok quota"
          />
        </picture>
      </figure>
      <figure class="preview-shot preview-web">
        <picture>
          <source
            srcset="/screenshots/web-overview-dark-desktop.png"
            media="(prefers-color-scheme: dark)"
            width="1440"
            height="900"
          />
          <img
            src="/screenshots/web-overview-light-desktop.png"
            width="1440"
            height="900"
            alt="Quota account overview with remaining-quota cards for Codex, Claude Code, and Grok"
          />
        </picture>
      </figure>
      <figure class="preview-shot preview-ios">
        <picture>
          <source
            srcset="/screenshots/ios-overview-dark.png"
            media="(prefers-color-scheme: dark)"
            width="1206"
            height="2622"
          />
          <img
            src="/screenshots/ios-overview-light.png"
            width="1206"
            height="2622"
            alt="Quota for iPhone overview showing remaining quota on Codex, Claude Code, and Grok"
          />
        </picture>
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
        <h3>Web &amp; iPhone show the same numbers</h3>
        <p>Sign in to see remaining quota, Usage, and Devices in the browser and on iPhone.</p>
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
      </article>
    </div>
  </section>
</div>
