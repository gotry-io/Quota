import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(root, "../src/app.html"), "utf8");
const landing = readFileSync(join(root, "../src/routes/+page.svelte"), "utf8");
const layout = readFileSync(join(root, "../src/routes/+layout.svelte"), "utf8");
const header = readFileSync(join(root, "../src/lib/components/Header.svelte"), "utf8");
const theme = readFileSync(join(root, "../src/lib/components/ThemeToggle.svelte"), "utf8");
const styles = readFileSync(join(root, "../src/app.css"), "utf8");
const overview = readFileSync(join(root, "../src/routes/my/+page.svelte"), "utf8");
const usage = readFileSync(join(root, "../src/routes/my/usage/+page.svelte"), "utf8");
const devices = readFileSync(join(root, "../src/routes/my/devices/+page.svelte"), "utf8");
const settings = readFileSync(join(root, "../src/routes/my/settings/+page.svelte"), "utf8");
const accountLayout = readFileSync(join(root, "../src/routes/my/+layout.svelte"), "utf8");
const accountNav = readFileSync(join(root, "../src/lib/components/AccountNav.svelte"), "utf8");

test("homepage introduces QuotaBar and both install paths", () => {
  assert.match(landing, /Know what you have left/);
  assert.match(landing, /Download QuotaBar \.dmg/);
  assert.match(
    landing,
    /https:\/\/github.com\/gotry-io\/Quota\/releases\/latest\/download\/QuotaBar-macos-arm64.dmg/,
  );
  assert.match(landing, /brew install gotry-io\/tap\/quotabar/);
  assert.match(landing, /aria-live="polite"/);
  assert.match(landing, /copied \? "Copied" : "Copy"/);
  assert.match(header, /Continue with GitHub/);
  assert.match(header, /id="header-account"/);
  assert.doesNotMatch(header, /ThemeToggle/);
  assert.match(layout, /footer-controls/);
  assert.match(layout, /ThemeToggle/);
  assert.match(layout, /© \{year\} GoTry IO · MIT/);
  assert.match(theme, /id = "theme-toggle"/);
  assert.match(theme, /quota-theme/);
  assert.match(theme, /\["system", "light", "dark"\]/);
  assert.match(theme, /localStorage\.removeItem/);
  assert.match(theme, /prefers-color-scheme: dark/);
  assert.match(html, /quota-theme/);
  assert.match(html, /prefers-color-scheme: dark/);
  assert.match(styles, /color-scheme: light dark/);
  assert.match(styles, /light-dark\(/);
  assert.match(styles, /grid-template-columns: repeat\(2, minmax\(0, 1fr\)\)/);
});

test("the hero shows remaining quota, with its reset and how fresh it is", () => {
  assert.match(landing, /class="provider-list"/);
  assert.match(landing, /class="quota-track"/);
  assert.match(landing, /Resets Thu 4:03 PM · Updated 3m ago/);
});

test("no surface explains itself in implementation words", () => {
  for (const source of [landing, overview, usage, devices, settings, accountLayout, accountNav]) {
    assert.doesNotMatch(source, /coverage/i);
    assert.doesNotMatch(source, /UTC-hour/i);
    assert.doesNotMatch(source, /fingerprint/i);
    assert.doesNotMatch(source, /revision/i);
    assert.doesNotMatch(source, /Rust/);
  }
});

test("the dashboard leads with subscriptions and one usage headline", () => {
  assert.ok(overview.indexOf('id="quota-title"') < overview.indexOf('id="today-title"'));
  assert.match(accountLayout, /<h1 id="dashboard-title">Quota<\/h1>/);
  assert.match(accountNav, /aria-label="Account"/);
  assert.match(overview, /providerDisplayName\(subscription\.provider\)/);
  assert.match(overview, /id="today-title"/);
  assert.match(usage, /id="token-total"/);
  assert.match(usage, /id="cost-total"/);
  assert.match(devices, /id="device-list"/);
  assert.match(settings, /searchParams\.get\("delete"\) !== "account"/);
});
