<script lang="ts">
/**
 * What a new Account with no Mac sees in place of data: install QuotaBar, sign in to Quota with
 * the same method, connect a provider.
 */
let { title }: { title: string } = $props();
</script>

<section class="setup" aria-labelledby="setup-title">
  <span class="eyebrow">No Mac reporting yet</span>
  <h2 id="setup-title">{title}</h2>
  <p>
    QuotaBar reads your agents on a Mac. Once it is signed in to this Account, models, usage, and
    quota appear here within a minute.
  </p>
  <ol>
    <li>Install QuotaBar on your Mac.</li>
    <li>Choose <b>Sign in to Quota</b> with the method you used here.</li>
    <li>Connect Claude Code, Codex, or any other provider.</li>
  </ol>
  <div class="setup-actions">
    <a class="pill primary" href="/download">Download for macOS</a>
    <a class="pill" href="/support">How Quota reads providers</a>
  </div>
</section>

<style>
.setup {
  display: grid;
  gap: 12px;
  justify-items: start;
  max-width: 640px;
  padding: 28px 0 40px;
  border-top: 1px solid var(--hairline);
}

h2 {
  font-family: var(--rounded);
  font-size: 22px;
  font-weight: 500;
}

p,
ol {
  margin: 0;
  color: var(--body);
  font-size: 15px;
}

ol {
  display: grid;
  gap: 4px;
  padding-left: 20px;
}

b {
  color: var(--ink);
  font-weight: 600;
}

.setup-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}
</style>
