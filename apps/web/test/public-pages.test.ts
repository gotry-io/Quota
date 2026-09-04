import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

const pages = ["download", "support", "privacy", "terms"] as const;

test("public pages exist and set head metadata", () => {
  for (const page of pages) {
    const file = join(root, "src/routes", page, "+page.svelte");
    assert.equal(existsSync(file), true, file);
    const source = readFileSync(file, "utf8");
    assert.match(source, /<svelte:head>/);
    assert.match(source, /<title>/);
    assert.match(source, /rel="canonical"/);
  }
});

test("footer links to the public pages", () => {
  const layout = readFileSync(join(root, "src/routes/+layout.svelte"), "utf8");
  for (const href of ["/download", "/support", "/privacy", "/terms"]) {
    assert.match(layout, new RegExp(`href="${href}"`));
  }
});
