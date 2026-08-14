<script lang="ts">
const brewCommand = "brew install gotry-io/tap/quotabar";

let copied = $state(false);
let copiedReset: ReturnType<typeof setTimeout> | undefined;

async function copyBrew(): Promise<void> {
  await navigator.clipboard.writeText(brewCommand);
  copied = true;
  clearTimeout(copiedReset);
  copiedReset = setTimeout(() => {
    copied = false;
  }, 1600);
}
</script>

<div id="landing-view">
  <section class="hero" aria-labelledby="hero-title">
    <div class="hero-copy">
      <p class="eyebrow">macOS menu bar · Your devices</p>
      <h1 id="hero-title">Know what you have left.</h1>
      <p class="hero-summary">
        QuotaBar shows remaining Codex, Claude, Grok, Cursor, and API-key quota from the menu bar.
        Usage stays on your machines unless you sync an account. Optionally publish a public page at
        /u/your-github-username.
      </p>
      <div class="hero-actions">
        <a
          class="button button-primary"
          href="https://github.com/gotry-io/Quota/releases/latest/download/QuotaBar-macos-arm64.dmg"
          >Download QuotaBar .dmg</a
        >
        <a class="button button-secondary" href="#product">See how it works</a>
      </div>
      <div class="install-panel">
        <div class="install-copy">
          <p class="install-label">Homebrew</p>
          <p class="install-note">Install or update QuotaBar from the tap.</p>
        </div>
        <div class="brew-row">
          <code id="brew-install">{brewCommand}</code>
          <button
            class="button button-secondary install-copy-button"
            type="button"
            onclick={() => void copyBrew()}
          >
            {copied ? "Copied" : "Copy"}
          </button>
          <span class="visually-hidden" aria-live="polite">{copied ? "Copied" : ""}</span>
        </div>
      </div>
      <p class="release-note">Apple Silicon · Open source · GitHub is the only sign-in</p>
    </div>

    <figure class="product-preview account-preview">
      <figcaption class="visually-hidden">Quota account summary preview</figcaption>
      <div class="preview-header">
        <div>
          <p class="preview-title">August Usage</p>
          <p class="provider-meta">3 devices · calculated API-equivalent cost</p>
        </div>
        <span class="coverage-tag">Complete</span>
      </div>
      <div class="metric-preview">
        <div><span>Tokens</span><strong>42.8M</strong></div>
        <div><span>Estimated</span><strong>$68.42</strong></div>
      </div>
      <div class="preview-breakdown">
        <div><span>Studio Mac</span><strong>22.1M</strong></div>
        <div><span>Build server</span><strong>14.6M</strong></div>
        <div><span>Laptop</span><strong>6.1M</strong></div>
      </div>
      <div class="preview-footer">
        <span>Unknown prices stay unpriced</span>
        <span>UTC-hour facts</span>
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
        QuotaBar's private Rust service owns installation identity, login, collection, state, and
        upload. The Swift UI renders only its safe typed output. The managed service stores
        normalized snapshots and sparse hourly facts—not provider credentials or raw logs.
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
        ><span>Private Rust service and device-scoped upload</span>
      </div>
      <span class="flow-arrow" aria-hidden="true">↓</span>
      <div class="flow-node">
        <span class="diagram-tag">Account</span><strong>Web + QuotaBar</strong><span
          >Normalized totals, devices, coverage, and cost</span
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
