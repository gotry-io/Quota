#!/usr/bin/env node
import { existsSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
/**
 * Regenerate docs/providers/README.md, the provider capability matrix.
 *
 * Hand-edited source: the `capabilities` block of each provider in
 * `packages/provider/catalog.json`, validated by `packages/provider/catalog.schema.json`.
 *
 * Presence of a capability is the catalog's statement; four keys are additionally anchored to the
 * catalog fields that already decide them, so the two cannot drift. Provenance is checked here:
 * a `fixture` claim must name a file that exists and a JSON pointer that resolves, and a `live`
 * claim must name a date that has already happened.
 */

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const checkOnly = process.argv.slice(2).includes("--check");
if (process.argv.slice(2).some((argument) => argument !== "--check")) {
  throw new Error("Usage: generate-capability-matrix.mjs [--check]");
}

/** Column groups, in the order the matrix prints them. */
const GROUPS = [
  { id: "quota", heading: "Quota windows" },
  { id: "usage", heading: "Usage" },
  { id: "channel", heading: "Collection" },
  { id: "account", heading: "Account sync" },
  { id: "status", heading: "Status page" },
  { id: "pricing", heading: "Cost" },
];

/**
 * Every capability key the catalog may claim, in the order a cell lists them. The key set here is
 * the same one `catalog.schema.json` accepts; a key in one and not the other is a bug this script
 * refuses rather than renders.
 */
const CAPABILITIES = [
  { key: "quota.per_minute", group: "quota", label: "per minute" },
  { key: "quota.five_hour", group: "quota", label: "5-hour" },
  { key: "quota.daily", group: "quota", label: "daily" },
  { key: "quota.weekly", group: "quota", label: "weekly" },
  { key: "quota.monthly", group: "quota", label: "monthly" },
  { key: "quota.plan_cycle", group: "quota", label: "plan cycle" },
  { key: "quota.balance", group: "quota", label: "balance" },
  { key: "usage.local_logs", group: "usage", label: "local logs" },
  { key: "channel.cli_credentials", group: "channel", label: "CLI credentials" },
  { key: "channel.api_key", group: "channel", label: "API key" },
  { key: "channel.browser_session_macos", group: "channel", label: "browser session (macOS)" },
  { key: "channel.web_session_ios", group: "channel", label: "web session (iOS)" },
  { key: "account.sync", group: "account", label: "uploads to the Account" },
  { key: "status.statuspage_v2", group: "status", label: "Statuspage v2" },
  { key: "pricing.api_equivalent", group: "pricing", label: "API-equivalent" },
  { key: "pricing.source_reported", group: "pricing", label: "source-reported" },
];

/**
 * Capability keys the catalog's own fields already decide. The predicate is the rule; a
 * `capabilities.validated` map that disagrees with it is refused, so these cells state only how
 * the capability was validated and never whether it exists.
 */
const ANCHORS = [
  {
    key: "channel.api_key",
    rule: "credential_config is not null",
    holds: (entry) => entry.credential_config !== null,
  },
  {
    key: "channel.browser_session_macos",
    rule: "browser_session is not null",
    holds: (entry) => entry.browser_session !== null,
  },
  { key: "account.sync", rule: "account_sync is true", holds: (entry) => entry.account_sync },
  {
    key: "status.statuspage_v2",
    rule: 'status_page.kind is "statuspage_v2"',
    holds: (entry) => entry.status_page?.kind === "statuspage_v2",
  },
];

const MARKS = { fixture: "F", live: "L", test: "T", unverified: "U" };

const catalogPath = "packages/provider/catalog.json";
// A test that wants a catalog with something wrong in it points here at a copy. It must not rewrite
// the real file: other generators read it, their tests run beside this one, and a reader that
// arrives between the truncate and the write sees an empty catalog.
const catalogSource = process.env.QUOTA_CAPABILITY_CATALOG ?? join(root, catalogPath);
const catalog = JSON.parse(readFileSync(catalogSource, "utf8"));
const schema = JSON.parse(
  readFileSync(join(root, "packages/provider/catalog.schema.json"), "utf8"),
);
assertKeySetsAgree(schema);
const providers = [...catalog.providers].sort((a, b) => a.order - b.order);
for (const entry of providers) {
  validateProvider(entry);
}
writeGenerated("docs/providers/README.md", render(providers));

function assertKeySetsAgree(document) {
  const declared = document.$defs?.capabilities?.properties?.validated?.propertyNames?.enum;
  if (!Array.isArray(declared)) {
    throw new Error("catalog.schema.json: capabilities.validated has no propertyNames enum");
  }
  const rendered = CAPABILITIES.map((capability) => capability.key);
  if (
    declared.length !== rendered.length ||
    declared.some((key, index) => key !== rendered[index])
  ) {
    throw new Error(
      `Capability key sets disagree. Schema: ${declared.join(", ")}. Generator: ${rendered.join(", ")}.`,
    );
  }
}

function validateProvider(entry) {
  const capabilities = entry.capabilities;
  if (!capabilities) {
    throw new Error(`${catalogPath}: provider ${entry.id} has no capabilities block`);
  }
  if (!existsSync(join(root, `docs/providers/${entry.id}.md`))) {
    throw new Error(`${catalogPath}: provider ${entry.id} has no docs/providers/${entry.id}.md`);
  }
  const known = new Set(CAPABILITIES.map((capability) => capability.key));
  for (const key of Object.keys(capabilities.validated)) {
    if (!known.has(key)) {
      throw new Error(`${catalogPath}: provider ${entry.id} claims unknown capability ${key}`);
    }
  }
  if (
    !CAPABILITIES.some((capability) => held(entry, capability.key) && capability.group === "quota")
  ) {
    throw new Error(
      `${catalogPath}: provider ${entry.id} claims no quota window; every catalog provider has a collector`,
    );
  }
  for (const anchor of ANCHORS) {
    if (anchor.holds(entry) !== held(entry, anchor.key)) {
      throw new Error(
        `${catalogPath}: provider ${entry.id} must claim ${anchor.key} exactly when ${anchor.rule}`,
      );
    }
  }
  for (const [key, validation] of Object.entries(capabilities.validated)) {
    validateProvenance(entry.id, key, validation);
  }
  validateKnownGaps(entry);
}

/**
 * A first-class provider's gap is named once and can only shrink: an unverified cell it does not
 * list is refused, and a listed key it has since closed is refused too, so the list cannot go
 * stale. A best-effort provider lists nothing; the Unverified table already says everything.
 */
function validateKnownGaps(entry) {
  const gaps = entry.capabilities.known_gaps;
  const unverified = Object.entries(entry.capabilities.validated)
    .filter(([, validation]) => validation.kind === "unverified")
    .map(([key]) => key);
  if (entry.capabilities.tier !== "first_class") {
    if (gaps.length > 0) {
      throw new Error(
        `${catalogPath}: provider ${entry.id} is best_effort and must leave known_gaps empty`,
      );
    }
    return;
  }
  for (const key of unverified) {
    if (!gaps.includes(key)) {
      throw new Error(
        `${catalogPath}: first-class provider ${entry.id} has an unverified ${key} that capabilities.known_gaps does not name`,
      );
    }
  }
  for (const key of gaps) {
    if (!unverified.includes(key)) {
      throw new Error(
        `${catalogPath}: first-class provider ${entry.id} names ${key} in known_gaps and it is no longer unverified`,
      );
    }
  }
}

function validateProvenance(providerId, key, validation) {
  const where = `${catalogPath}: ${providerId} ${key}`;
  if (validation.kind === "fixture") {
    const path = join(root, validation.fixture);
    if (!existsSync(path) || !statSync(path).isFile()) {
      throw new Error(`${where} names fixture ${validation.fixture}, which is not a file`);
    }
    const text = readFileSync(path, "utf8");
    if (text.trim() === "") {
      throw new Error(`${where} names fixture ${validation.fixture}, which is empty`);
    }
    if (validation.fixture.endsWith(".json")) {
      if (validation.pointer === undefined) {
        throw new Error(`${where} names a .json fixture and must name the JSON pointer into it`);
      }
      resolvePointer(where, validation.fixture, JSON.parse(text), validation.pointer);
    } else if (validation.pointer !== undefined) {
      throw new Error(
        `${where} names pointer ${validation.pointer} into ${validation.fixture}, which is not JSON`,
      );
    }
    return;
  }
  if (validation.kind === "test") {
    const path = join(root, validation.file);
    if (!existsSync(path) || !statSync(path).isFile()) {
      throw new Error(`${where} names test file ${validation.file}, which is not a file`);
    }
    assertTestFunction(where, validation.file, readFileSync(path, "utf8"), validation.name);
    return;
  }
  if (validation.kind === "live") {
    const stamped = Date.parse(`${validation.date}T00:00:00Z`);
    if (Number.isNaN(stamped)) {
      throw new Error(`${where} names live date ${validation.date}, which is not a date`);
    }
    if (stamped > Date.now()) {
      throw new Error(`${where} names live date ${validation.date}, which has not happened`);
    }
    return;
  }
  if (validation.kind !== "unverified") {
    throw new Error(`${where} has unknown validation kind ${JSON.stringify(validation.kind)}`);
  }
}

/**
 * The named function must exist exactly once in that file and must be a test. A production
 * function with a tempting name is not evidence, so the attribute above it is what is checked:
 * `#[test]` / `#[tokio::test]` in Rust, `@Test` or an XCTest `test…` method in Swift.
 */
function assertTestFunction(where, file, text, name) {
  const lines = text.split(/\r?\n/);
  const keyword = file.endsWith(".swift") ? "func" : "fn";
  const declaration = new RegExp(`(?:^|[^A-Za-z0-9_])${keyword}\\s+${name}\\s*(?:<[^>]*>)?\\s*\\(`);
  const found = lines.flatMap((line, index) => (declaration.test(line) ? [index] : []));
  if (found.length === 0) {
    throw new Error(`${where}: ${file} defines no ${keyword} ${name}`);
  }
  if (found.length > 1) {
    throw new Error(`${where}: ${file} defines ${keyword} ${name} ${found.length} times`);
  }
  // Swift Testing puts `@Test` on the declaration's own line as often as above it.
  const attributes = [lines[found[0]].trim(), ...precedingAttributes(lines, found[0])];
  const isTest = file.endsWith(".swift")
    ? attributes.some((line) => line.includes("@Test")) || name.startsWith("test")
    : attributes.some((line) => line === "#[test]" || line.startsWith("#[tokio::test"));
  if (!isTest) {
    throw new Error(`${where}: ${file} defines ${keyword} ${name}, which is not a test`);
  }
}

/** The attribute and comment lines immediately above a declaration, nearest first. */
function precedingAttributes(lines, index) {
  const collected = [];
  for (let cursor = index - 1; cursor >= 0 && index - cursor <= 6; cursor -= 1) {
    const line = lines[cursor].trim();
    if (line === "" || line.startsWith("//")) {
      continue;
    }
    if (line.startsWith("#[") || line.startsWith("@")) {
      collected.push(line);
      continue;
    }
    break;
  }
  return collected;
}

/** RFC 6901. A pointer that names nothing is the drift this check exists to catch. */
function resolvePointer(where, fixture, document, pointer) {
  let node = document;
  for (const raw of pointer.split("/").slice(1)) {
    const token = raw.replaceAll("~1", "/").replaceAll("~0", "~");
    if (Array.isArray(node)) {
      const index = Number(token);
      if (!Number.isInteger(index) || index < 0 || index >= node.length) {
        throw new Error(`${where}: ${fixture} has no ${pointer}`);
      }
      node = node[index];
      continue;
    }
    if (node === null || typeof node !== "object" || !Object.hasOwn(node, token)) {
      throw new Error(`${where}: ${fixture} has no ${pointer}`);
    }
    node = node[token];
  }
  return node;
}

function held(entry, key) {
  return Object.hasOwn(entry.capabilities.validated, key);
}

function render(entries) {
  const matrixRows = entries.map((entry) => {
    const cells = GROUPS.map((group) => groupCell(entry, group.id));
    return `| [${escapeCell(entry.display_name)}](${entry.id}.md) | ${tierLabel(entry)} | ${cells.join(" | ")} |`;
  });
  const evidenceRows = entries.flatMap((entry) =>
    CAPABILITIES.filter(
      (capability) =>
        held(entry, capability.key) &&
        entry.capabilities.validated[capability.key].kind !== "unverified",
    ).map((capability) => {
      const validation = entry.capabilities.validated[capability.key];
      return `| \`${entry.id}\` | \`${capability.key}\` | ${MARKS[validation.kind]} | ${evidence(validation)} |`;
    }),
  );
  const unverifiedRows = entries.flatMap((entry) =>
    CAPABILITIES.filter(
      (capability) =>
        held(entry, capability.key) &&
        entry.capabilities.validated[capability.key].kind === "unverified",
    ).map((capability) => {
      const note = entry.capabilities.validated[capability.key].note;
      return `| \`${entry.id}\` | \`${capability.key}\` | ${note ? escapeCell(note) : "—"} |`;
    }),
  );
  const anchorRows = ANCHORS.map(
    (anchor) => `| \`${anchor.key}\` | \`${escapeCell(anchor.rule)}\` |`,
  );
  const counts = entries.map((entry) => countValidation(entry));
  const firstClass = entries.filter((entry) => entry.capabilities.tier === "first_class");
  const gapLines = firstClass.map((entry) => {
    const gaps = entry.capabilities.known_gaps;
    const named = gaps.map((key) => `\`${key}\``).join(", ");
    return gaps.length === 0
      ? `- \`${entry.id}\` — no gap. Every capability it has is F, T, or L.`
      : `- \`${entry.id}\` — ${named}.`;
  });

  return `<!-- Generated by scripts/generate-capability-matrix.mjs — do not edit. -->
# Provider capability matrix

What Quota can do with each catalog provider, and how this repository knows. Generated from the
\`capabilities\` block of \`packages/provider/catalog.json\`; do not edit this file by hand, run
\`pnpm generate:capability-matrix\`. Per-provider request, parser, and credential specifics stay in
\`docs/providers/<id>.md\`, linked from each row; the common ladder stays in
[\`provider-collection.md\`](../provider-collection.md) and local Usage parsers in
[\`usage-sources.md\`](../usage-sources.md).

A capability is listed only when Quota has it. Every listing carries how it was validated:

- **F** — a recorded fixture in this repository covers it, named with its path (and JSON pointer)
  under [Evidence](#evidence).
- **T** — one named test asserts it, from a response held inline rather than in a fixture file. The
  file and the test function are under [Evidence](#evidence), and \`--check\` proves the function
  exists there and carries a test attribute.
- **L** — validated against a real provider account, on the date under [Evidence](#evidence).
- **U** — unverified. Nothing in this repository proves it; the reading may be right and no test
  says so. Every one is listed under [Unverified](#unverified).

${firstClass.length} of these ${entries.length} providers are first-class: ${firstClass
    .map((entry) => escapeCell(entry.display_name))
    .join(" and ")}. No new provider is added this
cycle; both statements are [ADR 0060](../decisions/0060-provider-freeze-and-two-tiers.md).

## Matrix

A \`—\` is a capability Quota does not have, not a capability it has and got wrong. An empty
**Status page** is a provider with no machine-readable Statuspage v2 feed; the catalog may still
carry its human page.

| Provider | Tier | ${GROUPS.map((group) => group.heading).join(" | ")} |
| --- | --- | ${GROUPS.map(() => "---").join(" | ")} |
${matrixRows.join("\n")}

Validated cells per provider:

| Provider | Tier | F | T | L | U |
| --- | --- | --- | --- | --- | --- |
${counts.map((count) => `| \`${count.id}\` | ${count.tier} | ${count.fixture} | ${count.test} | ${count.live} | ${count.unverified} |`).join("\n")}

## Evidence

Every **F**, **T**, and **L** cell above. \`--check\` fails when a fixture path or JSON pointer does
not resolve, or a named test function is absent from the file that is supposed to hold it or is not
a test, so evidence that is moved or rewritten cannot leave a stale claim behind.

| Provider | Capability | Kind | Evidence |
| --- | --- | --- | --- |
${evidenceRows.join("\n")}

## Unverified

Capabilities Quota has and this repository does not prove. This is the freeze cycle's work, not a
list of defects.

| Provider | Capability | What does cover it |
| --- | --- | --- |
${unverifiedRows.join("\n")}

## First-class gaps

A first-class provider's unverified cells are named in \`capabilities.known_gaps\`, so the gap can
only shrink: \`--check\` refuses an unverified cell the list does not name, and refuses a listed key
that is no longer unverified.

${gapLines.join("\n")}

## Anchored keys

Four capability keys are not free text: the catalog's own fields decide whether the provider has
them, and \`--check\` refuses a \`capabilities\` block that disagrees. The rest are declared from
what the collector and \`docs/providers/<id>.md\` say.

| Capability | Listed exactly when |
| --- | --- |
${anchorRows.join("\n")}

## Window kinds

The seven \`quota.*\` keys name the window kinds a collector emits, as
\`docs/providers/<id>.md\` titles them. \`five_hour\`, \`weekly\`, and \`monthly\` are the protocol's
\`primary_cadence\` members — the meter a reader means when they ask how much is left.

| Key | Window |
| --- | --- |
| \`quota.per_minute\` | A per-minute request allowance. |
| \`quota.five_hour\` | A five-hour window. |
| \`quota.daily\` | A window that resets each day. Not a \`primary_cadence\` member. |
| \`quota.weekly\` | A seven-day window. |
| \`quota.monthly\` | A monthly or 30-day window. |
| \`quota.plan_cycle\` | A meter over the plan's billing cycle with no duration of its own. |
| \`quota.balance\` | A window reporting absolute remaining value (\`remaining_value\` with a \`value_unit\`) rather than only a percentage. |
`;
}

function groupCell(entry, group) {
  const listed = CAPABILITIES.filter(
    (capability) => capability.group === group && held(entry, capability.key),
  ).map((capability) => {
    const validation = entry.capabilities.validated[capability.key];
    return `${escapeCell(capability.label)} ${MARKS[validation.kind]}`;
  });
  return listed.length === 0 ? "—" : listed.join(" · ");
}

function tierLabel(entry) {
  return entry.capabilities.tier === "first_class" ? "First-class" : "Best-effort";
}

function countValidation(entry) {
  const kinds = Object.values(entry.capabilities.validated).map((validation) => validation.kind);
  return {
    id: entry.id,
    tier: tierLabel(entry),
    fixture: kinds.filter((kind) => kind === "fixture").length,
    test: kinds.filter((kind) => kind === "test").length,
    live: kinds.filter((kind) => kind === "live").length,
    unverified: kinds.filter((kind) => kind === "unverified").length,
  };
}

function evidence(validation) {
  const note = validation.note ? ` — ${escapeCell(validation.note)}` : "";
  if (validation.kind === "fixture") {
    const link = `[\`${validation.fixture}\`](../../${validation.fixture})`;
    const pointer = validation.pointer ? ` \`${escapeCell(validation.pointer)}\`` : "";
    return `${link}${pointer}${note}`;
  }
  if (validation.kind === "test") {
    return `[\`${validation.file}\`](../../${validation.file}) \`${validation.name}\`${note}`;
  }
  return `${validation.date}${note}`;
}

function escapeCell(value) {
  return String(value).replaceAll("|", "\\|");
}

function writeGenerated(relativePath, contents) {
  const path = join(root, relativePath);
  if (checkOnly) {
    if (!existsSync(path) || readFileSync(path, "utf8") !== contents) {
      throw new Error(`Generated file is out of date: ${relativePath}`);
    }
    console.log(`${relativePath} is current`);
    return;
  }
  writeFileSync(path, contents);
  console.log(`wrote ${relativePath}`);
}
