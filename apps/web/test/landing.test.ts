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
  assert.doesNotMatch(landing, /Open Quota/);
  assert.match(header, /id="header-account"/);
  assert.doesNotMatch(header, /ThemeToggle/);
  assert.match(layout, /footer-controls/);
  assert.match(layout, /ThemeToggle/);
  assert.match(layout, /© \{year\} GoTry IO · MIT/);
  assert.doesNotMatch(layout, /gotry-io contributors/);
  assert.match(theme, /id="theme-toggle"/);
  assert.match(theme, /quota-theme/);
  assert.match(theme, /\["system", "light", "dark"\]/);
  assert.match(theme, /localStorage\.removeItem/);
  assert.match(theme, /prefers-color-scheme: dark/);
  assert.match(html, /quota-theme/);
  assert.match(html, /prefers-color-scheme: dark/);
  assert.match(styles, /color-scheme: light dark/);
  assert.match(styles, /light-dark\(/);
  assert.match(styles, /grid-template-columns: repeat\(2, minmax\(0, 1fr\)\)/);
  assert.doesNotMatch(landing, /id="export-quota"/);
  assert.doesNotMatch(landing, /\/u\//);
  assert.doesNotMatch(html, /\/u\//);
  assert.doesNotMatch(html, /__quotaAccountRequest/);
  assert.doesNotMatch(html, /data-session/);
});
