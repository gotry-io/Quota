import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { agentDisplayName, BILLING_AGENTS } from "@gotry-io/quota-protocol";
import { IOS_AVAILABILITY } from "../src/lib/platforms.ts";
import { AGENT_DISPLAY_NAMES, PROVIDER_DISPLAY_NAMES } from "../src/lib/providers.ts";

const root = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(root, "../src/app.html"), "utf8");
const landing = readFileSync(join(root, "../src/routes/+page.svelte"), "utf8");
const install = readFileSync(join(root, "../src/lib/components/InstallOptions.svelte"), "utf8");
const providers = readFileSync(join(root, "../src/lib/providers.ts"), "utf8");
const platforms = readFileSync(join(root, "../src/lib/platforms.ts"), "utf8");
const support = readFileSync(join(root, "../src/content/support.md"), "utf8");
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
  assert.match(landing, /See what's left across your coding-agent plans\./);
  assert.match(
    landing,
    /QuotaBar reads your providers on the Mac; Relay syncs only remaining quota and Usage totals/,
  );
  assert.match(landing, /Free &amp; open source · MIT · macOS 14\+/);
  assert.match(landing, /Download for macOS/);
  assert.match(landing, /Sign in with GitHub/);
  assert.match(landing, /signInHref/);
  assert.match(landing, /InstallOptions/);
  assert.match(
    install,
    /https:\/\/github.com\/gotry-io\/Quota\/releases\/latest\/download\/QuotaBar-macos-arm64.dmg/,
  );
  assert.match(install, /brew install gotry-io\/tap\/quotabar/);
  assert.match(install, /aria-live="polite"/);
  assert.match(install, /copied \? "Copied" : "Copy"/);
  assert.match(landing, /id="platforms"/);
  assert.match(header, /Sign in with GitHub/);
  assert.match(header, /id="header-account"/);
  assert.match(header, /Settings/);
  assert.match(header, /Sign out/);
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
  assert.match(styles, /clamp\(36px, 5vw, 56px\)/);
});

test("the hero uses real light and dark screenshots, not a coded mock", () => {
  assert.match(landing, /quotabar-overview-light\.png/);
  assert.match(landing, /quotabar-overview-dark\.png/);
  assert.match(landing, /web-overview-light-desktop\.png/);
  assert.match(landing, /web-overview-dark-desktop\.png/);
  assert.match(landing, /ios-overview-light\.png/);
  assert.match(landing, /ios-overview-dark\.png/);
  assert.match(landing, /shot-light/);
  assert.match(landing, /shot-dark/);
  assert.match(landing, />Preview</);
  assert.match(styles, /html\[data-theme="dark"\] \.preview-shot \.shot-dark/);
  assert.match(styles, /html:not\(\[data-theme\]\) \.preview-shot \.shot-dark/);
  assert.match(landing, /width="640"/);
  assert.match(landing, /height="960"/);
  assert.doesNotMatch(landing, /class="provider-list"/);
  assert.doesNotMatch(landing, /class="quota-track"/);
});

test("works-with names come from the catalog and billing agents", () => {
  assert.match(providers, /packages\/provider\/catalog\.json/);
  assert.match(landing, /CATALOG_PROVIDERS/);
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
  assert.match(landing, /What never leaves your Mac/);
  assert.match(landing, /Provider credentials, prompts, and local paths never leave your Mac\./);
  assert.match(landing, /Quota uploads remaining quota and privacy-preserving Usage totals only\./);
  assert.match(landing, /href="\/privacy"/);
});

test("iPhone availability is a switchable constant, default coming soon", () => {
  assert.equal(IOS_AVAILABILITY, "coming-soon");
  assert.match(platforms, /"coming-soon" \| "testflight" \| "app-store"/);
  assert.match(platforms, /url\?: string/);
  assert.match(platforms, /actionLabel\?: string/);
  assert.match(landing, /IOS_AVAILABILITY/);
  assert.match(landing, /iosAvailabilityCopy/);
  assert.match(landing, /ios\.url && ios\.actionLabel/);
  assert.match(platforms, /iPhone app coming soon/);
  assert.doesNotMatch(landing, /apps\.apple\.com/);
  assert.doesNotMatch(landing, /itunes\.apple\.com/);
});

test("Support does not use current iPhone availability copy while coming soon", () => {
  assert.equal(IOS_AVAILABILITY, "coming-soon");
  assert.match(support, /### When is Quota for iPhone available\?/);
  assert.match(support, /Quota for iPhone is coming soon\./);
  assert.match(support, /When it ships, it will read the Account reported by QuotaBar\./);
  assert.doesNotMatch(support, /Why is there no data on iPhone\?/);
  assert.doesNotMatch(support, /Quota for iPhone (?:reads|is a read-only|and the website read)/);
  assert.doesNotMatch(support, /the iPhone (?:has nothing to show|app shows)/i);
  assert.doesNotMatch(support, /It shows what a Mac running QuotaBar/);
});

test("the homepage does not advertise an App Store destination", () => {
  assert.doesNotMatch(landing, /App Store/);
  assert.doesNotMatch(landing, /apps\.apple\.com/);
  assert.doesNotMatch(landing, /itunes\.apple\.com/);
});

test("the landing keeps canonical and Open Graph", () => {
  assert.match(landing, /rel="canonical"/);
  assert.match(landing, /property="og:title"/);
  assert.match(landing, /property="og:url"/);
  assert.doesNotMatch(landing, /application\/ld\+json/);
});

test("the landing does not keep slogan blocks", () => {
  assert.doesNotMatch(landing, /Know what you have left/);
  assert.doesNotMatch(landing, /One quiet place/);
  assert.doesNotMatch(landing, /Collect · persist · sync/);
  assert.doesNotMatch(landing, /Bring every device into one view/);
  assert.match(landing, /How it works/);
  assert.match(landing, /Install QuotaBar/);
  assert.match(landing, /reads your providers locally/);
  assert.match(landing, /The web shows the same numbers/);
  assert.doesNotMatch(landing, /on iPhone/);
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
  assert.match(accountLayout, /id="dashboard-title"/);
  assert.match(header, /AccountNav/);
  assert.match(header, /account-avatar-fallback/);
  assert.doesNotMatch(header, /githubAvatarUrl/);
  assert.match(accountNav, /aria-label="Account"/);
  assert.match(overview, /providerDisplayName\(subscription\.provider\)/);
  assert.match(overview, /id="today-title"/);
  assert.match(overview, /today-strip/);
  assert.match(overview, /devices-strip/);
  assert.doesNotMatch(overview, /Installations/);
  assert.match(usage, /id="token-total"/);
  assert.match(usage, /id="cost-total"/);
  assert.match(usage, /id="message-total"/);
  assert.match(usage, />Messages</);
  assert.match(usage, /usage-columns/);
  assert.match(usage, /totals\.messages/);
  assert.match(devices, /id="device-list"/);
  assert.match(devices, /sortDevicesByLastSeen/);
  assert.match(devices, /Last contact/);
  assert.match(devices, /device-card-list/);
  assert.match(settings, /searchParams\.get\("delete"\) !== "account"/);
  assert.doesNotMatch(settings, /notifications-title/);
  assert.doesNotMatch(settings, /Sign out/);
  assert.match(settings, /id="appearance-title"/);
  assert.match(settings, /id="account-title"/);
  assert.match(settings, /id="legal-title"/);
});
