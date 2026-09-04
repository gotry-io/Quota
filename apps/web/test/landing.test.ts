import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { agentDisplayName, BILLING_AGENTS } from "@gotry-io/quota-protocol";
import { AGENT_DISPLAY_NAMES, PROVIDER_DISPLAY_NAMES } from "../src/lib/providers.ts";

const root = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(root, "../src/app.html"), "utf8");
const landing = readFileSync(join(root, "../src/routes/+page.svelte"), "utf8");
const install = readFileSync(join(root, "../src/lib/components/InstallOptions.svelte"), "utf8");
const providers = readFileSync(join(root, "../src/lib/providers.ts"), "utf8");
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
const catalog = JSON.parse(
  readFileSync(join(root, "../../../packages/provider/catalog.json"), "utf8"),
) as { providers: Array<{ display_name: string; order: number }> };

test("homepage introduces QuotaBar and both install paths", () => {
  assert.match(landing, /Know what you have left/);
  assert.match(landing, /InstallOptions/);
  assert.match(install, /Download QuotaBar \.dmg/);
  assert.match(
    install,
    /https:\/\/github.com\/gotry-io\/Quota\/releases\/latest\/download\/QuotaBar-macos-arm64.dmg/,
  );
  assert.match(install, /brew install gotry-io\/tap\/quotabar/);
  assert.match(install, /aria-live="polite"/);
  assert.match(install, /copied \? "Copied" : "Copy"/);
  assert.match(landing, /brew install gotry-io\/tap\/quotabar/);
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

test("the hero uses real light and dark screenshots, not a coded mock", () => {
  assert.equal((landing.match(/<picture>/g) ?? []).length, 2);
  assert.match(landing, /quotabar-overview-light\.png/);
  assert.match(landing, /quotabar-overview-dark\.png/);
  assert.match(landing, /web-overview-light-desktop\.png/);
  assert.match(landing, /web-overview-dark-desktop\.png/);
  assert.match(landing, /prefers-color-scheme: dark/);
  assert.match(landing, /width="640"/);
  assert.match(landing, /height="960"/);
  assert.doesNotMatch(landing, /class="provider-list"/);
  assert.doesNotMatch(landing, /class="quota-track"/);
});

test("works-with names come from the catalog and billing agents", () => {
  assert.match(providers, /packages\/provider\/catalog\.json/);
  assert.match(landing, /PROVIDER_DISPLAY_NAMES/);
  assert.match(landing, /AGENT_DISPLAY_NAMES/);
  const catalogNames = catalog.providers
    .slice()
    .sort((left, right) => left.order - right.order)
    .map((provider) => provider.display_name);
  assert.equal(catalogNames.length, 8);
  assert.deepEqual(PROVIDER_DISPLAY_NAMES, catalogNames);
  assert.equal(AGENT_DISPLAY_NAMES.length, 6);
  assert.deepEqual(
    AGENT_DISPLAY_NAMES,
    BILLING_AGENTS.map((agent) => agentDisplayName(agent)),
  );
  for (const name of catalogNames) {
    assert.doesNotMatch(landing, new RegExp(`>${name}<`));
  }
});

test("the privacy callout is the documented sentence and links /privacy", () => {
  assert.match(
    landing,
    /Provider credentials, prompts, and local paths never leave your Mac\. Quota uploads remaining\s+quota and privacy-preserving Usage totals only\./,
  );
  assert.match(landing, /href="\/privacy"/);
  assert.match(landing, /Quota for iPhone: coming soon/);
});

test("the homepage does not advertise an App Store destination", () => {
  assert.doesNotMatch(landing, /App Store/);
  assert.doesNotMatch(landing, /apps\.apple\.com/);
  assert.doesNotMatch(landing, /itunes\.apple\.com/);
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
