#!/usr/bin/env node
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
/**
 * Regenerate docs/reference.md from existing source and configuration.
 *
 * Hand-edited sources: packages/provider/catalog.json, packages/protocol (version constants
 * and schema/*.json), package/project files, packages/design-tokens/tokens.json.
 */

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const checkOnly = process.argv.slice(2).includes("--check");
if (process.argv.slice(2).some((argument) => argument !== "--check")) {
  throw new Error("Usage: generate-reference.mjs [--check]");
}

const catalog = readJson("packages/provider/catalog.json");
const tokens = readJson("packages/design-tokens/tokens.json");
const protocolSource = readFileSync(join(root, "packages/protocol/src/index.ts"), "utf8");
const controlVersion = readExportedNumberConst(protocolSource, "PROTOCOL_VERSION");
const managedVersion = readExportedNumberConst(protocolSource, "MANAGED_DATA_PROTOCOL_VERSION");
const contents = renderReference({
  catalog,
  tokens,
  controlVersion,
  managedVersion,
  schemas: readSchemaInventory(),
  units: collectWorkspaceUnits(),
});
writeGenerated("docs/reference.md", contents);

function readJson(relativePath) {
  return JSON.parse(readFileSync(join(root, relativePath), "utf8"));
}

function readExportedNumberConst(source, name) {
  const match = source.match(new RegExp(`^export const ${name} = (\\d+) as const;`, "m"));
  if (!match) {
    throw new Error(`packages/protocol/src/index.ts: missing export const ${name} = N as const`);
  }
  return Number(match[1]);
}

function readSchemaInventory() {
  const dir = join(root, "packages/protocol/schema");
  return readdirSync(dir)
    .filter((name) => name.endsWith(".json"))
    .sort()
    .map((name) => {
      const schema = readJson(`packages/protocol/schema/${name}`);
      return {
        file: name,
        id: typeof schema.$id === "string" ? schema.$id : "",
        title: typeof schema.title === "string" ? schema.title : name,
      };
    });
}

function collectWorkspaceUnits() {
  const units = new Map();
  units.set(".", inspectUnit("."));
  for (const dir of listChildDirs("apps").concat(listChildDirs("packages"))) {
    units.set(dir, inspectUnit(dir));
  }
  for (const member of readCargoWorkspaceMembers()) {
    if (!units.has(member)) {
      units.set(member, inspectUnit(member));
    }
  }
  return [...units.values()].sort((a, b) => a.path.localeCompare(b.path));
}

function listChildDirs(parent) {
  return readdirSync(join(root, parent), { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && !entry.name.startsWith("."))
    .map((entry) => `${parent}/${entry.name}`)
    .sort();
}

function inspectUnit(relativePath) {
  const dir = join(root, relativePath);
  const unit = { path: relativePath === "." ? "." : relativePath };
  const packageJsonPath = join(dir, "package.json");
  if (existsSync(packageJsonPath)) {
    const pkg = JSON.parse(readFileSync(packageJsonPath, "utf8"));
    unit.npm = {
      name: pkg.name ?? relativePath,
      scripts: Object.keys(pkg.scripts ?? {}),
    };
  }
  const cargoPath = join(dir, "Cargo.toml");
  if (existsSync(cargoPath)) {
    const cargo = parseCargoToml(readFileSync(cargoPath, "utf8"));
    if (cargo.name || cargo.lib || cargo.bins.length > 0) {
      unit.cargo = cargo;
    }
  }
  const swiftPath = join(dir, "Package.swift");
  if (existsSync(swiftPath)) {
    unit.swift = parsePackageSwift(readFileSync(swiftPath, "utf8"));
  }
  const xcodegenPath = join(dir, "project.yml");
  if (existsSync(xcodegenPath)) {
    unit.xcodegen = parseXcodegenName(readFileSync(xcodegenPath, "utf8"));
  }
  if (existsSync(join(dir, "catalog.json"))) {
    unit.catalog = `${relativePath}/catalog.json`;
  }
  if (existsSync(join(dir, "tokens.json"))) {
    unit.tokens = `${relativePath}/tokens.json`;
  }
  return unit;
}

function readCargoWorkspaceMembers() {
  const text = readFileSync(join(root, "Cargo.toml"), "utf8");
  const block = text.match(/members\s*=\s*\[([\s\S]*?)\]/);
  if (!block) {
    throw new Error("Cargo.toml: missing workspace members");
  }
  return [...block[1].matchAll(/"([^"]+)"/g)].map((match) => match[1]);
}

function parseCargoToml(text) {
  const name = text.match(/\[package\][\s\S]*?^name\s*=\s*"([^"]+)"/m)?.[1] ?? null;
  const lib = text.match(/\[lib\][\s\S]*?^name\s*=\s*"([^"]+)"/m)?.[1] ?? null;
  const bins = [...text.matchAll(/\[\[bin\]\][\s\S]*?^name\s*=\s*"([^"]+)"/gm)].map(
    (match) => match[1],
  );
  return { name, lib, bins };
}

function parsePackageSwift(text) {
  const name = text.match(/let package = Package\(\s*name:\s*"([^"]+)"/)?.[1] ?? null;
  const products = [...text.matchAll(/\.(executable|library)\(\s*name:\s*"([^"]+)"/g)].map(
    (match) => ({ kind: match[1], name: match[2] }),
  );
  return { name, products };
}

function parseXcodegenName(text) {
  const match = text.match(/^name:\s*(\S+)/m);
  return match ? match[1] : null;
}

function renderReference({ catalog, tokens, controlVersion, managedVersion, schemas, units }) {
  const providers = [...catalog.providers].sort((a, b) => a.order - b.order);
  const providerRows = providers.map((entry) => {
    const credential = entry.credential_config?.kind ?? "—";
    const browser = entry.browser_session
      ? entry.browser_session.exclusive
        ? "exclusive"
        : "yes"
      : "—";
    const status = entry.status_page?.kind ?? "—";
    const env = (entry.environment_keys ?? []).join(", ") || "—";
    const base = entry.default_base_url ?? "—";
    return `| ${entry.order} | [\`${entry.id}\`](providers/${entry.id}.md) | ${escapeCell(entry.display_name)} | ${entry.account_sync} | ${entry.default_visible} | ${escapeCell(entry.setup_action)} | ${escapeCell(credential)} | ${browser} | ${escapeCell(status)} | ${escapeCell(env)} | ${escapeCell(base)} |`;
  });
  const schemaRows = schemas.map((schema) => {
    const id = schema.id ? ` \`${schema.id}\`` : "";
    return `- [\`${schema.file}\`](../packages/protocol/schema/${schema.file}) — ${escapeCell(schema.title)}${id}`;
  });
  const colorLeaves = collectColorLeaves(tokens.color);
  const colorRows = colorLeaves.map((leaf) => {
    const css = [...leaf.css, ...leaf.cssDark].join(", ") || "—";
    return `| \`color.${leaf.path}\` | \`${leaf.light}\` | \`${leaf.dark}\` | ${escapeCell(css)} |`;
  });
  const thresholdRows = Object.entries(tokens.threshold)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([name, value]) => `| \`${name}\` | ${value} |`);
  const radiusRows = Object.entries(tokens.radius)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([name, value]) => `| \`${name}\` | ${value} |`);
  const overrideRows = flattenLeaves(tokens.overrides)
    .sort((a, b) => a.path.localeCompare(b.path))
    .map((leaf) => `| \`${leaf.path}\` | ${escapeCell(formatValue(leaf.value))} |`);

  return `<!-- Generated by scripts/generate-reference.mjs — do not edit. -->
# Reference

Generated static inventory from existing source and configuration. Do not edit this file by
hand; run \`pnpm generate:reference\`. This page does not describe production deployment status.

Canonical prose: [architecture](architecture.md), [security](security.md),
[provider collection](provider-collection.md), [usage sources](usage-sources.md),
[design](design.md). Decision records: [ADR index](decisions/README.md).

## Providers

From \`packages/provider/catalog.json\`. What Quota can do with each id, and what validates it, is
the generated [provider capability matrix](providers/README.md). Strategy for each catalog id is
[\`docs/providers/<id>.md\`](provider-collection.md#providers).

| Order | Id | Display name | Account sync | Default visible | Setup | Credential | Browser session | Status page | Environment keys | Default base URL |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
${providerRows.join("\n")}

## Protocol

From \`packages/protocol/src/index.ts\` exported constants, not from route source.

| Constant | Value | Role |
| --- | --- | --- |
| \`PROTOCOL_VERSION\` | ${controlVersion} | OAuth, Device control, Account metadata, catalogs |
| \`MANAGED_DATA_PROTOCOL_VERSION\` | ${managedVersion} | Quota, Usage, and Account summary |

JSON Schemas in \`packages/protocol/schema/\` (published under \`/schema/\`):

${schemaRows.join("\n")}

This list is not an HTTP route catalog. Routes are defined by those schemas and exercised by
the Relay tests under [\`apps/relay/test/\`](../apps/relay/test/) and the wire cases in
[\`packages/protocol/fixtures/wire-conformance.json\`](../packages/protocol/fixtures/wire-conformance.json).

## Workspace

Entry points and scripts from package and project files. Root \`package.json\` first, then
\`apps/*\`, \`packages/*\`, and Cargo workspace members.

${units.map(renderUnit).join("\n\n")}

## Design tokens

From \`packages/design-tokens/tokens.json\`.

### Color roles

| Role | Light | Dark | CSS |
| --- | --- | --- | --- |
${colorRows.join("\n")}

### Thresholds

| Role | Value |
| --- | --- |
${thresholdRows.join("\n")}

### Spacing

${tokens.spacing.map((size) => `\`${size}\``).join(", ")}

### Radius

| Role | Value |
| --- | --- |
${radiusRows.join("\n")}

### Overrides

| Path | Value |
| --- | --- |
${overrideRows.join("\n")}
`;
}

function renderUnit(unit) {
  const title = unit.path === "." ? "`.` (repository root)" : `\`${unit.path}\``;
  const lines = [`### ${title}`];
  if (unit.npm) {
    lines.push(`npm package \`${unit.npm.name}\`.`);
    if (unit.npm.scripts.length > 0) {
      lines.push(`Scripts: ${unit.npm.scripts.map((name) => `\`${name}\``).join(", ")}.`);
    }
  }
  if (unit.cargo) {
    const bits = [];
    if (unit.cargo.name) {
      bits.push(`crate \`${unit.cargo.name}\``);
    }
    if (unit.cargo.lib) {
      bits.push(`lib \`${unit.cargo.lib}\``);
    }
    if (unit.cargo.bins.length > 0) {
      bits.push(`bins ${unit.cargo.bins.map((name) => `\`${name}\``).join(", ")}`);
    }
    if (bits.length > 0) {
      lines.push(`Cargo ${bits.join("; ")}.`);
    }
  }
  if (unit.swift) {
    const products = unit.swift.products
      .map((product) => `${product.kind} \`${product.name}\``)
      .join(", ");
    const name = unit.swift.name ? ` \`${unit.swift.name}\`` : "";
    lines.push(`Swift package${name}${products ? `: ${products}` : ""}.`);
  }
  if (unit.xcodegen) {
    const projectFile = unit.path === "." ? "project.yml" : `${unit.path}/project.yml`;
    lines.push(
      `XcodeGen project \`${unit.xcodegen}\` ([\`project.yml\`](${mdPath(projectFile)})).`,
    );
  }
  if (unit.catalog) {
    lines.push(`Provider catalog ([\`catalog.json\`](${mdPath(unit.catalog)})).`);
  }
  if (unit.tokens) {
    lines.push(`Design tokens ([\`tokens.json\`](${mdPath(unit.tokens)})).`);
  }
  if (lines.length === 1) {
    lines.push("No package.json, Cargo.toml, Package.swift, or project.yml.");
  }
  return lines.join("\n");
}

function mdPath(relativePath) {
  return relative(join(root, "docs"), join(root, relativePath)).split("\\").join("/");
}

function collectColorLeaves(node, path = []) {
  if (node && typeof node.light === "string" && typeof node.dark === "string") {
    return [
      {
        path: path.join("."),
        light: node.light,
        dark: node.dark,
        css: node.css ?? [],
        cssDark: node.css_dark ?? [],
      },
    ];
  }
  if (!node || typeof node !== "object" || Array.isArray(node)) {
    return [];
  }
  return Object.entries(node).flatMap(([key, child]) => collectColorLeaves(child, [...path, key]));
}

function flattenLeaves(node, path = []) {
  if (node === null || typeof node !== "object" || Array.isArray(node)) {
    return [{ path: path.join("."), value: node }];
  }
  const entries = Object.entries(node);
  if (entries.length === 0) {
    return [{ path: path.join("."), value: node }];
  }
  return entries.flatMap(([key, value]) => flattenLeaves(value, [...path, key]));
}

function formatValue(value) {
  if (value && typeof value === "object") {
    return JSON.stringify(value);
  }
  return String(value);
}

function escapeCell(value) {
  return String(value).replaceAll("|", "\\|");
}

function writeGenerated(relativePath, contents) {
  const path = join(root, relativePath);
  if (checkOnly) {
    if (readFileSync(path, "utf8") !== contents) {
      throw new Error(`Generated file is out of date: ${relativePath}`);
    }
    console.log(`${relativePath} is current`);
    return;
  }
  writeFileSync(path, contents);
  console.log(`wrote ${relativePath}`);
}
