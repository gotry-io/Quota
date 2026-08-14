import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(root, "../src/app.html"), "utf8");
const landing = readFileSync(join(root, "../src/routes/+page.svelte"), "utf8");
const header = readFileSync(join(root, "../src/lib/components/Header.svelte"), "utf8");
const theme = readFileSync(join(root, "../src/lib/components/ThemeToggle.svelte"), "utf8");

test("homepage introduces QuotaBar and both install paths", () => {
  assert.match(landing, /Know what you have left/);
  assert.match(landing, /Download QuotaBar \.dmg/);
  assert.match(
    landing,
    /https:\/\/github.com\/gotry-io\/Quota\/releases\/latest\/download\/QuotaBar-macos-arm64.dmg/,
  );
  assert.match(landing, /brew install gotry-io\/tap\/quotabar/);
  assert.match(header, /Continue with GitHub/);
  assert.doesNotMatch(landing, /Open Quota/);
  assert.match(header, /id="header-account"/);
  assert.match(theme, /id="theme-toggle"/);
  assert.match(html, /quota-theme/);
  assert.match(html, /prefers-color-scheme: dark/);
  assert.doesNotMatch(landing, /id="export-quota"/);
  assert.doesNotMatch(landing, /id="public-profile-form"/);
  assert.doesNotMatch(html, /__quotaAccountRequest/);
  assert.doesNotMatch(html, /data-session/);
});
