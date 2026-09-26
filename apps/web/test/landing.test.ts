import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const landing = readFileSync(join(root, "../src/routes/+page.svelte"), "utf8");
const platforms = readFileSync(join(root, "../src/lib/platforms.ts"), "utf8");
const download = readFileSync(join(root, "../src/routes/download/+page.svelte"), "utf8");
const home = readFileSync(join(root, "../src/routes/my/+page.svelte"), "utf8");
const models = readFileSync(join(root, "../src/routes/my/models/+page.svelte"), "utf8");
const quota = readFileSync(join(root, "../src/routes/my/quota/+page.svelte"), "utf8");
const recap = readFileSync(join(root, "../src/routes/my/recap/+page.svelte"), "utf8");
const subscription = readFileSync(
  join(root, "../src/lib/components/SubscriptionDetail.svelte"),
  "utf8",
);
const devices = readFileSync(join(root, "../src/routes/my/devices/+page.svelte"), "utf8");
const settings = readFileSync(join(root, "../src/routes/my/settings/+page.svelte"), "utf8");
const accountLayout = readFileSync(join(root, "../src/routes/my/+layout.svelte"), "utf8");
const accountNav = readFileSync(join(root, "../src/lib/components/AccountNav.svelte"), "utf8");
const band = readFileSync(join(root, "../src/lib/components/QuotaBand.svelte"), "utf8");
const catalog = JSON.parse(
  readFileSync(join(root, "../../../packages/provider/catalog.json"), "utf8"),
) as {
  providers: Array<{ id: string; brand_icon_asset: string }>;
};

// `release-menubar.yml` publishes `LATEST_DMG="QuotaBar-macos-arm64.dmg"` and the tap's cask.
test("the download links name the DMG and the tap the release publishes", () => {
  for (const page of [landing, download]) {
    assert.match(page, /QUOTABAR_DMG_URL/);
    assert.match(page, /BrewCommand/);
  }
  assert.match(
    platforms,
    /https:\/\/github.com\/gotry-io\/Quota\/releases\/latest\/download\/QuotaBar-macos-arm64.dmg/,
  );
  assert.match(platforms, /brew install gotry-io\/tap\/quotabar/);
});

test("every catalog provider mark resolves to a file", () => {
  assert.equal(catalog.providers.length, 12);
  for (const provider of catalog.providers) {
    const asset = join(root, `../static/providers/${provider.brand_icon_asset}.svg`);
    assert.equal(existsSync(asset), true, provider.brand_icon_asset);
    assert.match(readFileSync(asset, "utf8"), /fill="currentColor"/);
  }
});

test("no surface explains itself in implementation words", () => {
  for (const source of [
    landing,
    home,
    models,
    quota,
    recap,
    subscription,
    devices,
    settings,
    accountLayout,
    accountNav,
    band,
  ]) {
    assert.doesNotMatch(source, /coverage/i);
    assert.doesNotMatch(source, /UTC-hour/i);
    assert.doesNotMatch(source, /fingerprint/i);
    assert.doesNotMatch(source, /revision/i);
    assert.doesNotMatch(source, /Rust/);
  }
});
