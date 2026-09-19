#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, extname, join } from "node:path";
import { pathToFileURL } from "node:url";

/**
 * Summarize iOS UI accessibility `audit-outcome.*` attachments.
 *
 *   node scripts/ios-ui-audit-summary.mjs <path.xcresult> [--out-dir dir]
 *   node scripts/ios-ui-audit-summary.mjs <outcomes.json>
 *
 * The parsing/summarising half is unit-tested against a checked-in JSON fixture.
 * An `.xcresult` is exported with `xcrun xcresulttool export attachments`.
 */

export const AUDIT_TYPES = ["clipped", "contrast", "dynamic-type", "hit-region", "other"];
export const OUTCOME_CLASSES = ["passed", "confirmed", "unconfirmed", "incomplete"];
export const ATTACHMENT_PREFIX = "audit-outcome.";

const NON_CONTRAST_TYPES = AUDIT_TYPES.filter((type) => type !== "contrast");

export function parseOutcomeJson(text, source = "outcome.json") {
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch (error) {
    throw new Error(`${source}: invalid JSON (${error.message})`);
  }
  if (Array.isArray(parsed)) {
    return parsed.map((item, index) => parseOutcomeRecord(item, `${source}[${index}]`));
  }
  return [parseOutcomeRecord(parsed, source)];
}

export function recordsFromAttachments(files) {
  const records = [];
  for (const file of files) {
    const name = file.name || "";
    if (!isAuditOutcomeName(name)) continue;
    const source = file.source || name;
    records.push(...parseOutcomeJson(file.text, source));
  }
  return records;
}

export function isAuditOutcomeName(name) {
  const base = basename(name);
  return base === ATTACHMENT_PREFIX.slice(0, -1) || base.startsWith(ATTACHMENT_PREFIX);
}

export function summarizeOutcomes(records) {
  const rows = [...records].sort((a, b) => {
    const screen = a.screen.localeCompare(b.screen);
    if (screen !== 0) return screen;
    return a.test.localeCompare(b.test);
  });
  const perType = {};
  for (const type of AUDIT_TYPES) {
    perType[type] = { passed: 0, confirmed: 0, unconfirmed: 0, incomplete: 0 };
  }
  const exemptedTotals = {};
  for (const record of rows) {
    for (const type of AUDIT_TYPES) {
      const outcome = record.outcomes[type];
      if (outcome && perType[type][outcome] !== undefined) {
        perType[type][outcome] += 1;
      }
    }
    for (const [rule, count] of Object.entries(record.exempted)) {
      exemptedTotals[rule] = (exemptedTotals[rule] || 0) + count;
    }
  }

  const lines = [];
  lines.push("## iOS accessibility audit");
  lines.push("");
  const totals = [`Screens audited: ${rows.length}.`];
  for (const type of AUDIT_TYPES) {
    const counts = perType[type];
    totals.push(
      `${type}: ${counts.passed} passed / ${counts.confirmed} confirmed / ${counts.unconfirmed} unconfirmed / ${counts.incomplete} incomplete.`,
    );
  }
  lines.push(totals.join(" "));
  const exemptionParts = Object.keys(exemptedTotals)
    .sort()
    .filter((rule) => exemptedTotals[rule] > 0)
    .map((rule) => `${rule} ${exemptedTotals[rule]}`);
  if (exemptionParts.length > 0) {
    lines.push(`Exemptions: ${exemptionParts.join(", ")}.`);
  } else {
    lines.push("Exemptions: none.");
  }
  lines.push("");
  lines.push(`| Screen | Test | ${NON_CONTRAST_TYPES.join(" | ")} | Exemptions |`);
  lines.push(`| --- | --- | ${NON_CONTRAST_TYPES.map(() => "---").join(" | ")} | --- |`);
  for (const record of rows) {
    const cells = NON_CONTRAST_TYPES.map((type) => record.outcomes[type] || "—");
    lines.push(
      `| ${record.screen} | ${record.test} | ${cells.join(" | ")} | ${formatExempted(record.exempted)} |`,
    );
  }
  if (rows.length === 0) {
    lines.push("| — | — | — | — | — | — | — |");
  }
  lines.push("");
  lines.push("### Contrast (advisory)");
  lines.push("");
  lines.push(
    "Contrast never gates. Token contrast is `ContrastTokenTests`; this column is the iOS 26 pixel sampler.",
  );
  lines.push("");
  lines.push("| Screen | Test | Outcome | First pass | Second pass |");
  lines.push("| --- | --- | --- | --- | --- |");
  for (const record of rows) {
    lines.push(
      `| ${record.screen} | ${record.test} | ${record.outcomes.contrast || "—"} | ${countFindings(record.first_pass, "contrast")} | ${countFindings(record.second_pass, "contrast")} |`,
    );
  }
  if (rows.length === 0) {
    lines.push("| — | — | — | — | — |");
  }
  lines.push("");
  return lines.join("\n");
}

export function collectRecordsFromXcresult(xcresultPath, outDir) {
  const exportDir = mkdtempSync(join(tmpdir(), "ios-ui-audit-"));
  try {
    const exported = spawnSync(
      "xcrun",
      ["xcresulttool", "export", "attachments", "--path", xcresultPath, "--output-path", exportDir],
      { encoding: "utf8" },
    );
    if (exported.status !== 0) {
      throw new Error(
        `xcresulttool export attachments failed: ${(exported.stderr || exported.stdout || "").trim()}`,
      );
    }
    const manifestPath = join(exportDir, "manifest.json");
    if (!existsSync(manifestPath)) {
      throw new Error("xcresulttool did not write manifest.json");
    }
    const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
    const files = [];
    for (const test of Array.isArray(manifest) ? manifest : []) {
      const attachments = Array.isArray(test.attachments)
        ? test.attachments
        : test.attachments
          ? [test.attachments]
          : [];
      for (const attachment of attachments) {
        const raw = attachment.suggestedHumanReadableName || "";
        if (!isAuditOutcomeName(raw)) continue;
        const exportedFileName = attachment.exportedFileName;
        if (!exportedFileName) continue;
        const src = join(exportDir, exportedFileName);
        if (!existsSync(src)) {
          throw new Error(`missing exported attachment: ${src}`);
        }
        files.push({
          name: raw,
          source: raw,
          text: readFileSync(src, "utf8"),
        });
      }
    }
    const records = recordsFromAttachments(files);
    if (outDir) {
      mkdirSync(outDir, { recursive: true });
      const used = new Set();
      for (const record of records) {
        const destName = uniqueJsonName(
          used,
          `${ATTACHMENT_PREFIX}${record.screen}.${record.test}`,
        );
        writeFileSync(join(outDir, destName), `${JSON.stringify(record, null, 2)}\n`);
      }
    }
    return records;
  } finally {
    rmSync(exportDir, { recursive: true, force: true });
  }
}

function parseOutcomeRecord(value, source) {
  if (value == null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${source}: expected an outcome object`);
  }
  const screen = requiredString(value.screen, `${source}.screen`);
  const test = requiredString(value.test, `${source}.test`);
  const outcomes = {};
  const rawOutcomes = value.outcomes;
  if (rawOutcomes == null || typeof rawOutcomes !== "object" || Array.isArray(rawOutcomes)) {
    throw new Error(`${source}.outcomes: expected an object`);
  }
  for (const type of AUDIT_TYPES) {
    const outcome = rawOutcomes[type];
    if (outcome == null) continue;
    if (!OUTCOME_CLASSES.includes(outcome)) {
      throw new Error(`${source}.outcomes.${type}: unknown outcome ${JSON.stringify(outcome)}`);
    }
    outcomes[type] = outcome;
  }
  const exempted = {};
  const rawExempted = value.exempted;
  if (rawExempted != null) {
    if (typeof rawExempted !== "object" || Array.isArray(rawExempted)) {
      throw new Error(`${source}.exempted: expected an object`);
    }
    for (const [rule, count] of Object.entries(rawExempted)) {
      const n = Number(count);
      if (!Number.isFinite(n) || n < 0) {
        throw new Error(`${source}.exempted.${rule}: expected a count`);
      }
      exempted[rule] = n;
    }
  }
  return {
    screen,
    test,
    audit_types: Array.isArray(value.audit_types)
      ? value.audit_types.map(String)
      : [...AUDIT_TYPES],
    outcomes,
    exempted,
    first_pass: Array.isArray(value.first_pass) ? value.first_pass : [],
    second_pass:
      value.second_pass == null ? null : Array.isArray(value.second_pass) ? value.second_pass : [],
  };
}

function requiredString(value, label) {
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`${label}: expected a non-empty string`);
  }
  return value;
}

function formatExempted(exempted) {
  const parts = Object.keys(exempted)
    .sort()
    .filter((rule) => exempted[rule] > 0)
    .map((rule) => `${rule} ${exempted[rule]}`);
  return parts.length > 0 ? parts.join(", ") : "none";
}

function countFindings(pass, type) {
  if (!Array.isArray(pass)) return "—";
  return String(
    pass.filter(
      (finding) =>
        finding && finding.type === type && (finding.disposition ?? "recorded") === "recorded",
    ).length,
  );
}

function uniqueJsonName(used, raw) {
  const baseName = basename(raw);
  const withoutExt = extname(baseName) === ".json" ? baseName.slice(0, -5) : baseName;
  let candidate = `${withoutExt}.json`;
  let n = 2;
  while (used.has(candidate)) {
    candidate = `${withoutExt}-${n}.json`;
    n += 1;
  }
  used.add(candidate);
  return candidate;
}

function parseArgs(argv) {
  const args = [...argv];
  let outDir = null;
  const positional = [];
  while (args.length > 0) {
    const arg = args.shift();
    if (arg === "--out-dir") {
      outDir = args.shift();
      if (!outDir) throw new Error("--out-dir requires a directory");
      continue;
    }
    if (arg === "-h" || arg === "--help") {
      return { help: true };
    }
    positional.push(arg);
  }
  if (positional.length !== 1) {
    throw new Error(
      "usage: node scripts/ios-ui-audit-summary.mjs <xcresult|outcomes.json> [--out-dir dir]",
    );
  }
  return { help: false, input: positional[0], outDir };
}

function loadRecords(input, outDir) {
  if (input.endsWith(".json")) {
    const records = parseOutcomeJson(readFileSync(input, "utf8"), input);
    if (outDir) {
      mkdirSync(outDir, { recursive: true });
      writeFileSync(join(outDir, basename(input)), JSON.stringify(records, null, 2));
    }
    return records;
  }
  if (!existsSync(input)) {
    throw new Error(`no such xcresult: ${input}`);
  }
  return collectRecordsFromXcresult(input, outDir);
}

function main(argv = process.argv.slice(2)) {
  let parsed;
  try {
    parsed = parseArgs(argv);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 2;
    return;
  }
  if (parsed.help) {
    console.log(
      "usage: node scripts/ios-ui-audit-summary.mjs <xcresult|outcomes.json> [--out-dir dir]",
    );
    return;
  }
  try {
    const records = loadRecords(parsed.input, parsed.outDir);
    process.stdout.write(`${summarizeOutcomes(records)}\n`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

const isMain = process.argv[1] != null && pathToFileURL(process.argv[1]).href === import.meta.url;
if (isMain) {
  main();
}
