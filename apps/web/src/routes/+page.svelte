<script lang="ts">
import InstallOptions from "$lib/components/InstallOptions.svelte";
import { AGENT_DISPLAY_NAMES, PROVIDER_DISPLAY_NAMES } from "$lib/providers.ts";

const brewCommand = "brew install gotry-io/tap/quotabar";
</script>

<div id="landing-view">
  <section class="hero" aria-labelledby="hero-title">
    <div class="hero-copy">
      <p class="eyebrow">macOS menu bar · Your devices</p>
      <h1 id="hero-title">Know what you have left.</h1>
      <p class="hero-summary">
        QuotaBar shows remaining quota for eight providers from the menu bar, and keeps Usage on
        your Mac unless you sync an account.
      </p>
      <InstallOptions>
        <a class="button button-secondary" href="#product">See how it works</a>
      </InstallOptions>
      <p class="release-note">Apple Silicon · Open source · GitHub is the only sign-in</p>
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
            media="(min-width: 841px) and (prefers-color-scheme: dark)"
            width="1440"
            height="900"
          />
          <source
            srcset="/screenshots/web-overview-light-desktop.png"
            media="(min-width: 841px)"
            width="1440"
            height="900"
          />
          <source
            srcset="/screenshots/web-overview-dark-mobile.png"
            media="(prefers-color-scheme: dark)"
            width="390"
            height="844"
          />
          <img
            src="/screenshots/web-overview-light-mobile.png"
            width="390"
            height="844"
            alt="Quota account overview with remaining-quota cards for Codex, Claude Code, and Grok, and Studio Mac and Kitchen Mac"
          />
        </picture>
      </figure>
    </div>
  </section>

  <section class="works-with" aria-labelledby="works-with-title">
    <div class="section-heading">
      <p class="eyebrow">Providers · Agents</p>
      <h2 id="works-with-title">Works with the providers and agents you already use.</h2>
    </div>
    <div class="works-with-grid">
      <div>
        <h3>Works with</h3>
        <ul class="name-list">
          {#each PROVIDER_DISPLAY_NAMES as name (name)}
            <li>{name}</li>
          {/each}
        </ul>
      </div>
      <div>
        <h3>Usage from</h3>
        <ul class="name-list">
          {#each AGENT_DISPLAY_NAMES as name (name)}
            <li>{name}</li>
          {/each}
        </ul>
      </div>
    </div>
  </section>

  <section class="privacy-callout" aria-labelledby="privacy-title">
    <p class="eyebrow">Privacy</p>
    <h2 id="privacy-title" class="visually-hidden">What never leaves your Mac</h2>
    <p>
      Provider credentials, prompts, and local paths never leave your Mac. Quota uploads remaining
      quota and privacy-preserving Usage totals only. <a class="text-link" href="/privacy">Privacy</a
      >
    </p>
  </section>

  <section class="principles" id="product" aria-labelledby="product-title">
    <div class="section-heading">
      <p class="eyebrow">One quiet place</p>
      <h2 id="product-title">Quota and Usage without leaking the work.</h2>
    </div>
    <div class="principle-grid">
      <article>
        <span class="index">01</span>
        <h3>Local collection</h3>
        <p>
          Install QuotaBar from the .dmg or <code>{brewCommand}</code>. It reads eight provider
          sessions and six agents' logs locally. Credentials, prompts, paths, and raw events never
          upload.
        </p>
      </article>
      <article>
        <span class="index">02</span>
        <h3>One account</h3>
        <p>
          Sign in once per installation and see every active or signed-out device, with account
          totals and device breakdowns. Quota for iPhone: coming soon.
        </p>
      </article>
      <article>
        <span class="index">03</span>
        <h3>Defensible cost</h3>
        <p>
          Effective-dated channel prices calculate API-equivalent USD. Missing prices remain visible
          instead of becoming zero.
        </p>
      </article>
    </div>
  </section>

  <section class="architecture" aria-labelledby="architecture-title">
    <div class="architecture-copy">
      <p class="eyebrow">Direct by design</p>
      <h2 id="architecture-title">Account to device. Nothing in between.</h2>
      <p>
        QuotaBar reads eight provider sessions and six agents' logs on your Mac and uploads only the
        numbers: what quota is left and how many tokens you spent. Your account stores those
        totals—never provider credentials, prompts, paths, or raw logs.
      </p>
      <a class="text-link" href="https://github.com/gotry-io/Quota">Read the source →</a>
    </div>
    <div class="flow" role="img" aria-label="Quota data flow">
      <div class="flow-node">
        <span class="diagram-tag">Local</span><strong>Eight providers · six agents</strong><span
          >Quota and Usage remain readable offline</span
        >
      </div>
      <span class="flow-arrow" aria-hidden="true">↓</span>
      <div class="flow-node flow-node-dark">
        <span class="diagram-tag diagram-tag-dark">QuotaBar</span><strong>Collect · persist · sync</strong
        ><span>Your Mac reads the providers and sends only totals</span>
      </div>
      <span class="flow-arrow" aria-hidden="true">↓</span>
      <div class="flow-node">
        <span class="diagram-tag">Account</span><strong>Web + QuotaBar</strong><span
          >Remaining quota, every device, and what it cost</span
        >
      </div>
    </div>
  </section>

  <section class="cta">
    <div>
      <p class="eyebrow eyebrow-dark">Ready when you are</p>
      <h2>Bring every device into one view.</h2>
    </div>
    <a
      class="button button-on-dark"
      href="https://github.com/gotry-io/Quota/releases/latest/download/QuotaBar-macos-arm64.dmg"
      >Download QuotaBar .dmg</a
    >
  </section>
</div>
