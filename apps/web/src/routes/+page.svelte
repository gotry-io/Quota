<script lang="ts">
import InstallOptions from "$lib/components/InstallOptions.svelte";

const brewCommand = "brew install gotry-io/tap/quotabar";
</script>

<div id="landing-view">
  <section class="hero" aria-labelledby="hero-title">
    <div class="hero-copy">
      <p class="eyebrow">macOS menu bar · Your devices</p>
      <h1 id="hero-title">Know what you have left.</h1>
      <p class="hero-summary">
        QuotaBar shows remaining Codex, Claude, Grok, Cursor, and API-key quota from the menu bar.
        Usage stays on your machines unless you sync an account.
      </p>
      <InstallOptions>
        <a class="button button-secondary" href="#product">See how it works</a>
      </InstallOptions>
      <p class="release-note">Apple Silicon · Open source · GitHub is the only sign-in</p>
    </div>

    <figure class="product-preview account-preview">
      <figcaption class="visually-hidden">Quota remaining-quota preview</figcaption>
      <div class="preview-header">
        <div>
          <p class="preview-title">Quota</p>
          <p class="provider-meta">What is left, on every machine you sign in from</p>
        </div>
      </div>
      <div class="provider-list">
        <div class="provider-row">
          <div class="provider-title-line">
            <span>Codex</span>
            <span class="source-tag">Pro</span>
          </div>
          <div class="quota-window">
            <p class="quota-window-heading"><span>5 hour</span><strong>68%</strong></p>
            <div class="quota-track"><span style="width: 68%"></span></div>
            <p class="reset-time">Resets Thu 4:03 PM · Updated 3m ago</p>
          </div>
        </div>
        <div class="provider-row">
          <div class="provider-title-line">
            <span>Claude Code</span>
            <span class="source-tag">Max</span>
          </div>
          <div class="quota-window">
            <p class="quota-window-heading"><span>Weekly</span><strong>31%</strong></p>
            <div class="quota-track"><span style="width: 31%"></span></div>
            <p class="reset-time">Resets Sat 9:00 AM · Updated 3m ago</p>
          </div>
        </div>
        <div class="provider-row">
          <div class="provider-title-line">
            <span>OpenRouter</span>
          </div>
          <div class="quota-window">
            <p class="quota-window-heading"><span>Balance</span><strong>$12.50</strong></p>
            <p class="reset-time">No reset time reported · Updated 3m ago</p>
          </div>
        </div>
      </div>
      <div class="preview-footer">
        <span>Today · $4.18 · 1.2M tokens</span>
      </div>
    </figure>
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
          Install QuotaBar from the .dmg or <code>{brewCommand}</code>. It reads provider sessions
          and agent logs locally. Credentials, prompts, paths, and raw events never upload.
        </p>
      </article>
      <article>
        <span class="index">02</span>
        <h3>One account</h3>
        <p>
          Sign in once per installation and see every active or signed-out device, with account
          totals and device breakdowns.
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
        QuotaBar reads your provider sessions and agent logs on your Mac and uploads only the
        numbers: what quota is left and how many tokens you spent. Your account stores those
        totals—never provider credentials, prompts, paths, or raw logs.
      </p>
      <a class="text-link" href="https://github.com/gotry-io/Quota">Read the source →</a>
    </div>
    <div class="flow" role="img" aria-label="Quota data flow">
      <div class="flow-node">
        <span class="diagram-tag">Local</span><strong>Five coding agents</strong><span
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
