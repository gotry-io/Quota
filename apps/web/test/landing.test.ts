import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const html = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "../index.html"), "utf8");

test("homepage introduces QuotaBar and both install paths", () => {
  assert.match(html, /Know what you have left/);
  assert.match(html, /Download QuotaBar \.dmg/);
  assert.match(
    html,
    /https:\/\/github.com\/gotry-io\/Quota\/releases\/latest\/download\/QuotaBar-macos-arm64\.dmg/,
  );
  assert.match(html, /brew install gotry-io\/tap\/quotabar/);
  assert.match(html, /Continue with GitHub/);
  assert.doesNotMatch(html, /Open Quota/);
  assert.equal((html.match(/data-web-login/g) ?? []).length, 1);
  assert.doesNotMatch(html, /id="export-quota"/);
  assert.doesNotMatch(html, /id="public-profile-slug"/);
});
