#!/usr/bin/env node
// Whether every screen the iOS census audits is actually being audited.
//
// `incomplete` — the accessibility auditor hit its deadline — never fails a census run, by design:
// one slow audit is not a finding. A screen whose audit times out every night is therefore never
// audited and nothing says so. This reads the audit outcomes of the recent nightly runs and fails
// when a screen has stopped completing.
//
// A **key** is one (profile, screen, test). For a key:
//
//   - A run is **eligible** when that key appears in it at all. A screen that did not run in a
//     profile — its test skipped, the profile not captured, the screen added later or removed, or
//     the run's artifact expired so there is nothing to read — neither counts towards the window
//     nor resets it.
//   - The key is **completed** in an eligible run when the record reports at least one non-contrast
//     audit type and none of the non-contrast types it reports is `incomplete`. Contrast is ignored
//     entirely: it never gates, because the iOS 26 pixel sampler reports low contrast on system
//     label colour (`apps/ios/DESIGN.md`). A record that reports no non-contrast outcome at all is
//     not completed either — the auditor returned no non-contrast verdict, which is the same
//     silence this gate exists to notice. Two records for one key in one run are one eligible run,
//     completed only when both are.
//   - The key **fails** when it has at least N eligible runs and its most recent N eligible runs
//     are all not completed. Fewer than N eligible runs is not enough history and never fails.
//   - The key is **at risk** when k of its most recent N eligible runs are not completed and k is
//     at least 3. At risk is reported and never fails.
//
// Usage: ios-audit-trend.mjs --runs-dir <dir> [--n 5] [--out report.json]
//                            [--issue-body body.md] [--run-url URL]
//
// Each subdirectory of <dir> is one downloaded `ios-screens` artifact, named after the run id; the
// nightly workflow does the downloading, so the judgement here is offline and testable. Run ids
// increase with time within a repository, so the directory names order the window. Prints the
// Markdown report on stdout, exits 1 when a key fails and 2 on unusable input.
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import { AUDIT_TYPES, isAuditOutcomeName, parseOutcomeJson } from "./ios-ui-audit-summary.mjs";

/** How many eligible runs without a completed audit fail a key. */
export const DEFAULT_WINDOW = 5;
/** How many of the last N eligible runs without a completed audit are worth naming. */
export const AT_RISK_THRESHOLD = 3;

const NON_CONTRAST_TYPES = AUDIT_TYPES.filter((type) => type !== "contrast");
// `upload-artifact` strips the leading directory the uploaded paths share, which is `dist`, and
// `gh run download -n ios-screens -D runs/<id>` extracts a single named artifact into that
// directory itself. So one run's outcomes sit in
// `runs/<id>/ios-screens-outcomes/ios-screens-<profile>/audit-outcome.<screen>.<test>.json`.
const OUTCOMES_DIR = "ios-screens-outcomes";
const PROFILE_PREFIX = "ios-screens-";
const RUN_METADATA = "run.json";

/**
 * The verdict over `runs`, newest run first. Each run is
 * `{ runId, createdAt, outcomes: [{ profile, screen, test, types: { <audit type>: outcome } }] }`.
 */
export function evaluateTrend(runs, { n = DEFAULT_WINDOW } = {}) {
  if (!Array.isArray(runs)) {
    throw new TypeError("runs: expected an array of runs, newest first");
  }
  if (!Number.isInteger(n) || n < 1) {
    throw new RangeError(`--n: expected a positive integer, got ${JSON.stringify(n)}`);
  }

  const keys = new Map();
  const readRuns = [];
  for (const run of runs) {
    const runId = runIdOf(run);
    const createdAt = typeof run.createdAt === "string" ? run.createdAt : null;
    const perKey = mergeRunOutcomes(run, runId);
    readRuns.push({ run_id: runId, created_at: createdAt, screens: perKey.size });
    for (const [id, outcome] of perKey) {
      let key = keys.get(id);
      if (!key) {
        key = { ...outcome.key, eligible_runs: 0, window: [] };
        keys.set(id, key);
      }
      key.eligible_runs += 1;
      // The runs arrive newest first, so the first n eligible ones are the window.
      if (key.window.length < n) {
        key.window.push({
          run_id: runId,
          created_at: createdAt,
          completed: outcome.completed,
          incomplete_types: outcome.incompleteTypes,
        });
      }
    }
  }

  const rows = [...keys.values()]
    .map((key) => {
      const notCompleted = key.window.filter((one) => !one.completed).length;
      // The window holds min(n, eligible_runs) runs, so a full window of failures is the rule:
      // "at least n eligible runs and the most recent n are all not completed".
      const failed = key.window.length >= n && notCompleted === key.window.length;
      return {
        ...key,
        not_completed: notCompleted,
        status: failed
          ? "failed"
          : notCompleted >= AT_RISK_THRESHOLD
            ? "at-risk"
            : key.eligible_runs < n
              ? "short-history"
              : "completing",
      };
    })
    .sort(
      (a, b) =>
        a.profile.localeCompare(b.profile) ||
        a.screen.localeCompare(b.screen) ||
        a.test.localeCompare(b.test),
    );

  return {
    n,
    at_risk_threshold: AT_RISK_THRESHOLD,
    status: rows.some((row) => row.status === "failed") ? "failed" : "passed",
    runs: readRuns,
    keys: rows,
  };
}

/** The `$GITHUB_STEP_SUMMARY` report for a verdict. */
export function formatTrendReport(result) {
  const failed = result.keys.filter((row) => row.status === "failed");
  const atRisk = result.keys.filter((row) => row.status === "at-risk");
  const shortHistory = result.keys.filter((row) => row.status === "short-history");
  const lines = ["## iOS audit trend", ""];
  lines.push(
    `A screen with no completed non-contrast audit in its last ${result.n} eligible runs fails ` +
      "this job. Contrast is ignored; a run in which a screen did not run is not eligible, so it " +
      "neither counts nor resets. This never blocks a merge.",
  );
  lines.push("", `${describeWindow(result)} Screens tracked: ${result.keys.length}.`, "");
  if (failed.length === 0) {
    lines.push("**Every tracked screen completed an audit inside its window.**");
  } else {
    lines.push(
      `**${plural(failed.length, "screen")} ${failed.length === 1 ? "has" : "have"} not ` +
        `completed a non-contrast audit in ${failed.length === 1 ? "its" : "their"} last ` +
        `${result.n} eligible runs.**`,
      "",
      "### Not completing",
      "",
      ...table(failed),
    );
  }
  if (atRisk.length > 0) {
    lines.push(
      "",
      "### At risk (advisory)",
      "",
      `Not completed in at least ${result.at_risk_threshold} of the last ${result.n} eligible ` +
        "runs, but not yet in all of them.",
      "",
      ...table(atRisk),
    );
  }
  if (shortHistory.length > 0) {
    lines.push(
      "",
      `Not enough history to judge (fewer than ${result.n} eligible runs): ` +
        `${shortHistory.map((row) => `${row.profile} ${row.screen}`).join(", ")}.`,
    );
  }
  lines.push("");
  return lines.join("\n");
}

/** The issue body the nightly gate opens or comments with, for either verdict. */
export function formatIssueBody(result, { runUrl = null } = {}) {
  const failed = result.keys.filter((row) => row.status === "failed");
  const lines = [];
  if (failed.length === 0) {
    lines.push(
      `Cleared: every tracked screen has completed a non-contrast accessibility audit within its ` +
        `last ${result.n} eligible runs again. Closing.`,
    );
  } else {
    lines.push(
      `The iOS screen census has not completed a non-contrast accessibility audit for ` +
        `${plural(failed.length, "screen")} in ${failed.length === 1 ? "its" : "their"} last ` +
        `${result.n} eligible runs. An \`incomplete\` audit never fails a census run, so nothing ` +
        `below is being audited at all.`,
      "",
      ...table(failed),
    );
    const atRisk = result.keys.filter((row) => row.status === "at-risk");
    if (atRisk.length > 0) {
      lines.push(
        "",
        `Also not completing reliably: ${atRisk
          .map((row) => `${row.profile} ${row.screen} (${row.not_completed}/${row.window.length})`)
          .join(", ")}.`,
      );
    }
  }
  lines.push(
    "",
    describeWindow(result),
    "",
    "The rule, and why contrast is excluded, is the audit policy in `apps/ios/DESIGN.md`; the gate " +
      "is `scripts/ios-audit-trend.mjs`, run by the nightly `ios-screens` workflow. It never " +
      "blocks a merge.",
  );
  if (runUrl) {
    lines.push("", `Run: ${runUrl}`);
  }
  lines.push("");
  return lines.join("\n");
}

/** Every downloaded run under `dir`, newest first. */
export function readRunsDir(dir) {
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch (error) {
    throw new Error(`--runs-dir ${dir}: cannot be read (${error.message})`);
  }
  const runs = [];
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    if (!/^[0-9]+$/.test(entry.name)) {
      throw new Error(`${join(dir, entry.name)}: a run directory is named after its run id`);
    }
    runs.push(readRunDir(join(dir, entry.name), entry.name));
  }
  // Run ids increase with time within a repository, so this is newest first.
  return runs.sort((a, b) => Number(b.runId) - Number(a.runId));
}

/** One downloaded `ios-screens` artifact: its outcomes, one record per audited screen. */
export function readRunDir(path, runId) {
  const outcomes = [];
  const outcomesDir = join(path, OUTCOMES_DIR);
  // A run whose census job died before it exported outcomes carries no evidence, so it is eligible
  // for nothing. That is the same as the expired artifact the workflow could not download at all.
  if (existsSync(outcomesDir)) {
    for (const entry of readdirSync(outcomesDir, { withFileTypes: true })) {
      if (!entry.isDirectory() || !entry.name.startsWith(PROFILE_PREFIX)) continue;
      const profile = entry.name.slice(PROFILE_PREFIX.length);
      if (profile === "") {
        throw new Error(`${join(outcomesDir, entry.name)}: no profile in the directory name`);
      }
      for (const file of readdirSync(join(outcomesDir, entry.name)).sort()) {
        if (!isAuditOutcomeName(file)) continue;
        const source = join(outcomesDir, entry.name, file);
        for (const record of parseOutcomeJson(readFileSync(source, "utf8"), source)) {
          outcomes.push({
            profile,
            screen: record.screen,
            test: record.test,
            types: record.outcomes,
          });
        }
      }
    }
  }
  return { runId, createdAt: readCreatedAt(path), outcomes };
}

/** The timestamp the workflow wrote beside the download, for the report only. */
function readCreatedAt(path) {
  const metadata = join(path, RUN_METADATA);
  if (!existsSync(metadata)) return null;
  const parsed = JSON.parse(readFileSync(metadata, "utf8"));
  return typeof parsed.created_at === "string" ? parsed.created_at : null;
}

function runIdOf(run) {
  if (run == null || typeof run !== "object") {
    throw new TypeError("runs: expected an array of runs, newest first");
  }
  const runId = run.runId == null ? "" : String(run.runId);
  if (runId === "") throw new TypeError("run.runId: expected a run id");
  return runId;
}

/** One entry per key in one run: duplicates of a key are one eligible run, completed only if all are. */
function mergeRunOutcomes(run, runId) {
  const merged = new Map();
  if (run.outcomes != null && !Array.isArray(run.outcomes)) {
    throw new TypeError(`run ${runId}: outcomes must be an array`);
  }
  for (const outcome of run.outcomes ?? []) {
    const key = keyOf(outcome, runId);
    const id = `${key.profile} ${key.screen} ${key.test}`;
    const incompleteTypes = NON_CONTRAST_TYPES.filter(
      (type) => outcome.types?.[type] === "incomplete",
    );
    const reported = NON_CONTRAST_TYPES.filter((type) => outcome.types?.[type] != null);
    const completed = reported.length > 0 && incompleteTypes.length === 0;
    const existing = merged.get(id);
    if (!existing) {
      merged.set(id, { key, completed, incompleteTypes });
      continue;
    }
    existing.completed = existing.completed && completed;
    existing.incompleteTypes = [...new Set([...existing.incompleteTypes, ...incompleteTypes])];
  }
  return merged;
}

function keyOf(outcome, runId) {
  if (outcome == null || typeof outcome !== "object") {
    throw new TypeError(`run ${runId}: expected an outcome object`);
  }
  const { profile, screen, test } = outcome;
  for (const [name, value] of [
    ["profile", profile],
    ["screen", screen],
    ["test", test],
  ]) {
    if (typeof value !== "string" || value === "") {
      throw new TypeError(`run ${runId}: outcome.${name} must be a non-empty string`);
    }
  }
  return { profile, screen, test };
}

function table(rows) {
  const lines = [
    "| Profile | Screen | Test | Eligible runs | Not completed | Incomplete types (latest) |",
    "| --- | --- | --- | ---: | ---: | --- |",
  ];
  for (const row of rows) {
    const latest = row.window[0]?.incomplete_types ?? [];
    lines.push(
      `| ${row.profile} | ${row.screen} | ${row.test} | ${row.eligible_runs} | ` +
        `${row.not_completed}/${row.window.length} | ${latest.length > 0 ? latest.join(", ") : "none reported"} |`,
    );
  }
  return lines;
}

function describeWindow(result) {
  if (result.runs.length === 0) return "Runs read: none.";
  const newest = result.runs[0];
  const oldest = result.runs[result.runs.length - 1];
  const span =
    result.runs.length === 1
      ? describeRun(newest)
      : `${describeRun(oldest)} … ${describeRun(newest)}`;
  return `Runs read: ${result.runs.length} (${span}).`;
}

function describeRun(run) {
  return run.created_at ? `${run.run_id} ${run.created_at}` : run.run_id;
}

function plural(count, noun) {
  return `${count} ${noun}${count === 1 ? "" : "s"}`;
}

function parseArgs(argv) {
  const options = { runsDir: null, n: DEFAULT_WINDOW, out: null, issueBody: null, runUrl: null };
  const args = [...argv];
  while (args.length > 0) {
    const arg = args.shift();
    const value = () => {
      const next = args.shift();
      if (next == null) throw new Error(`${arg} requires a value`);
      return next;
    };
    switch (arg) {
      case "--runs-dir":
        options.runsDir = value();
        break;
      case "--n":
        options.n = Number(value());
        break;
      case "--out":
        options.out = value();
        break;
      case "--issue-body":
        options.issueBody = value();
        break;
      case "--run-url":
        options.runUrl = value();
        break;
      case "-h":
      case "--help":
        return { help: true };
      default:
        throw new Error(`unknown argument ${arg}`);
    }
  }
  if (!options.runsDir) throw new Error("--runs-dir is required");
  return { help: false, ...options };
}

const USAGE =
  "usage: ios-audit-trend.mjs --runs-dir <dir> [--n 5] [--out report.json]" +
  " [--issue-body body.md] [--run-url URL]";

function write(path, text) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, text);
}

function main(argv = process.argv.slice(2)) {
  let options;
  try {
    options = parseArgs(argv);
  } catch (error) {
    console.error(`${error.message}\n${USAGE}`);
    return 2;
  }
  if (options.help) {
    console.log(USAGE);
    return 0;
  }
  let result;
  try {
    result = evaluateTrend(readRunsDir(options.runsDir), { n: options.n });
  } catch (error) {
    console.error(error.message);
    return 2;
  }
  process.stdout.write(`${formatTrendReport(result)}\n`);
  if (options.out) write(options.out, `${JSON.stringify(result, null, 2)}\n`);
  if (options.issueBody) write(options.issueBody, formatIssueBody(result, options));
  return result.status === "failed" ? 1 : 0;
}

if (process.argv[1] != null && pathToFileURL(process.argv[1]).href === import.meta.url) {
  process.exit(main());
}
