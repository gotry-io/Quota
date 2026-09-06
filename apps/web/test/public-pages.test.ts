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

test("the published Usage page states its own head and loads only through the document port", () => {
  const page = readFileSync(join(root, "src/routes/u/[handle]/+page.svelte"), "utf8");
  assert.match(page, /<svelte:head>/);
  assert.match(page, /<title>/);
  assert.match(page, /rel="canonical"/);
  assert.match(page, /property="og:title"/);
  assert.match(page, /property="og:description"/);
  assert.match(page, /name="twitter:card"/);
  // Nothing about the reader, and nothing about the owner beyond the handle they published.
  for (const forbidden of [
    "data.viewer",
    "displayLabel",
    "signInHref",
    "account_id",
    "device_id",
    "subscriptions",
    "used_percent",
  ]) {
    assert.equal(page.includes(forbidden), false, forbidden);
  }

  const server = readFileSync(join(root, "src/routes/u/[handle]/+page.server.ts"), "utf8");
  assert.match(server, /locals\.document\.readPublicProfile\(params\.handle\)/);
  const specifiers = [...server.matchAll(/from\s+["']([^"']+)["']/g)].map((match) => match[1]);
  for (const specifier of specifiers) {
    assert.ok(
      specifier === "@sveltejs/kit" || specifier === "./$types",
      `unexpected import ${specifier}`,
    );
  }
});

test("a published page wears no account chrome", () => {
  const layout = readFileSync(join(root, "src/routes/+layout.svelte"), "utf8");
  assert.match(layout, /isPublicProfilePath\(page\.url\.pathname\)/);
  assert.match(layout, /<PublicPageHeader \/>/);

  const header = readFileSync(join(root, "src/lib/components/PublicPageHeader.svelte"), "utf8");
  for (const forbidden of ["viewer={", "signInHref", "AccountNav", "signOut(", "$props()"]) {
    assert.equal(header.includes(forbidden), false, forbidden);
  }
});
