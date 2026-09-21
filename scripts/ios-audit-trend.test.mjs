import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  AT_RISK_THRESHOLD,
  DEFAULT_WINDOW,
  evaluateTrend,
  formatIssueBody,
  formatTrendReport,
  readRunsDir,
} from "./ios-audit-trend.mjs";

const root = dirname(fileURLToPath(import.meta.url));
const script = join(root, "ios-audit-trend.mjs");

const PASSED = { clipped: "passed", "dynamic-type": "passed", "hit-region": "passed" };
const TIMED_OUT = {
  clipped: "incomplete",
  contrast: "incomplete",
  "dynamic-type": "incomplete",
  "hit-region": "incomplete",
};

/** One run, newest first in the array the trend reads. `types` per screen name. */
function run(runId, screens, { profile = "light-large", test: testName = "testScreens" } = {}) {
  return {
    runId,
    createdAt: `2026-09-${String(runId).slice(-2)}T03:40:00Z`,
    outcomes: Object.entries(screens).map(([screen, types]) => ({
      profile,
      screen,
      test: testName,
      types,
    })),
  };
}

function keyFor(result, screen) {
  const row = result.keys.find((one) => one.screen === screen);
  assert.ok(row, `no key for ${screen}`);
  return row;
}

test("five eligible runs without a completed audit fail the key", () => {
  const runs = [16, 15, 14, 13, 12].map((id) =>
    run(id, { "overview.root": PASSED, "usage.root": TIMED_OUT }),
  );
  const result = evaluateTrend(runs);
  assert.equal(result.n, DEFAULT_WINDOW);
  assert.equal(result.status, "failed");
  const usage = keyFor(result, "usage.root");
  assert.equal(usage.status, "failed");
  assert.equal(usage.eligible_runs, 5);
  assert.equal(usage.not_completed, 5);
  assert.deepEqual(usage.window[0].incomplete_types, ["clipped", "dynamic-type", "hit-region"]);
  assert.equal(keyFor(result, "overview.root").status, "completing");
});

test("fewer than N eligible runs is not enough history", () => {
  const runs = [16, 15, 14, 13].map((id) => run(id, { "usage.root": TIMED_OUT }));
  const result = evaluateTrend(runs);
  assert.equal(result.status, "passed");
  const usage = keyFor(result, "usage.root");
  assert.equal(usage.status, "at-risk");
  assert.equal(usage.eligible_runs, 4);
  assert.equal(usage.not_completed, 4);
});

test("a run in which the screen did not run neither counts nor resets", () => {
  // Six runs; the screen is absent from two of them, so five eligible runs still fail the key.
  const runs = [
    run(17, { "usage.root": TIMED_OUT }),
    run(16, { "overview.root": PASSED }),
    run(15, { "usage.root": TIMED_OUT }),
    run(14, { "overview.root": PASSED }),
    run(13, { "usage.root": TIMED_OUT }),
    run(12, { "usage.root": TIMED_OUT }),
    run(11, { "usage.root": TIMED_OUT }),
  ];
  const result = evaluateTrend(runs);
  const usage = keyFor(result, "usage.root");
  assert.equal(usage.eligible_runs, 5);
  assert.equal(usage.status, "failed");
  assert.deepEqual(
    usage.window.map((one) => one.run_id),
    ["17", "15", "13", "12", "11"],
  );
});

test("one completed audit inside the window clears the key", () => {
  const runs = [
    run(17, { "usage.root": TIMED_OUT }),
    run(16, { "usage.root": TIMED_OUT }),
    run(15, { "usage.root": PASSED }),
    run(14, { "usage.root": TIMED_OUT }),
    run(13, { "usage.root": TIMED_OUT }),
    run(12, { "usage.root": TIMED_OUT }),
  ];
  const result = evaluateTrend(runs);
  assert.equal(result.status, "passed");
  const usage = keyFor(result, "usage.root");
  assert.equal(usage.not_completed, 4);
  assert.equal(usage.status, "at-risk");
  assert.ok(AT_RISK_THRESHOLD <= 4);
});

test("contrast-only incompleteness is a completed audit", () => {
  const contrastOnly = { ...PASSED, contrast: "incomplete" };
  const runs = [16, 15, 14, 13, 12].map((id) => run(id, { "usage.root": contrastOnly }));
  const result = evaluateTrend(runs);
  assert.equal(result.status, "passed");
  const usage = keyFor(result, "usage.root");
  assert.equal(usage.status, "completing");
  assert.equal(usage.not_completed, 0);
  assert.deepEqual(usage.window[0].incomplete_types, []);
});

test("confirmed and unconfirmed findings are completed audits", () => {
  const found = { clipped: "confirmed", "dynamic-type": "unconfirmed", "hit-region": "passed" };
  const result = evaluateTrend([16, 15, 14, 13, 12].map((id) => run(id, { "usage.root": found })));
  assert.equal(result.status, "passed");
  assert.equal(keyFor(result, "usage.root").not_completed, 0);
});

test("a record with no non-contrast outcome is not completed", () => {
  const runs = [16, 15, 14, 13, 12].map((id) => run(id, { "usage.root": { contrast: "passed" } }));
  const result = evaluateTrend(runs);
  assert.equal(result.status, "failed");
  assert.deepEqual(keyFor(result, "usage.root").window[0].incomplete_types, []);
});

test("a screen added in the newest run has no history and cannot fail", () => {
  const runs = [
    run(17, { "overview.root": PASSED, "settings.providers": TIMED_OUT }),
    ...[16, 15, 14, 13].map((id) => run(id, { "overview.root": PASSED })),
  ];
  const result = evaluateTrend(runs);
  assert.equal(result.status, "passed");
  const added = keyFor(result, "settings.providers");
  assert.equal(added.eligible_runs, 1);
  assert.equal(added.status, "short-history");
  assert.match(formatTrendReport(result), /Not enough history to judge/);
});

test("profiles are separate keys and two records of one key are one eligible run", () => {
  const runs = [16, 15, 14, 13, 12].map((id) => ({
    runId: id,
    createdAt: null,
    outcomes: [
      { profile: "light-large", screen: "usage.root", test: "testScreens", types: TIMED_OUT },
      { profile: "light-large", screen: "usage.root", test: "testScreens", types: PASSED },
      { profile: "dark-large", screen: "usage.root", test: "testScreens", types: PASSED },
    ],
  }));
  const result = evaluateTrend(runs);
  assert.equal(result.keys.length, 2);
  const dark = result.keys.find((one) => one.profile === "dark-large");
  const light = result.keys.find((one) => one.profile === "light-large");
  assert.equal(dark.status, "completing");
  assert.equal(light.eligible_runs, 5);
  assert.equal(light.status, "failed");
});

test("N is configurable and the window follows it", () => {
  const runs = [16, 15, 14].map((id) => run(id, { "usage.root": TIMED_OUT }));
  assert.equal(evaluateTrend(runs, { n: 3 }).status, "failed");
  assert.equal(evaluateTrend(runs, { n: 4 }).status, "passed");
  assert.throws(() => evaluateTrend(runs, { n: 0 }), /positive integer/);
});

test("malformed input is refused rather than judged", () => {
  assert.throws(() => evaluateTrend(null), /expected an array of runs/);
  assert.throws(() => evaluateTrend([{ createdAt: null, outcomes: [] }]), /expected a run id/);
  assert.throws(() => evaluateTrend([{ runId: 1, outcomes: {} }]), /outcomes must be an array/);
  assert.throws(
    () => evaluateTrend([{ runId: 1, outcomes: [{ profile: "light-large", screen: "a" }] }]),
    /outcome\.test must be a non-empty string/,
  );
});

test("the report and the issue body name the failing screens and the window", () => {
  const runs = [16, 15, 14, 13, 12].map((id) => run(id, { "usage.root": TIMED_OUT }));
  const result = evaluateTrend(runs);
  const report = formatTrendReport(result);
  assert.match(report, /## iOS audit trend/);
  assert.match(report, /never blocks a merge/);
  assert.match(report, /Runs read: 5 \(12 2026-09-12T03:40:00Z … 16 2026-09-16T03:40:00Z\)/);
  assert.match(report, /\*\*1 screen has not completed a non-contrast audit in its last 5/);
  assert.match(report, /\| light-large \| usage\.root \| testScreens \| 5 \| 5\/5 \|/);

  const body = formatIssueBody(result, { runUrl: "https://example.test/run/16" });
  assert.match(body, /nothing below is being audited at all/);
  assert.match(body, /\| light-large \| usage\.root \| testScreens \| 5 \| 5\/5 \|/);
  assert.match(body, /apps\/ios\/DESIGN\.md/);
  assert.match(body, /Run: https:\/\/example\.test\/run\/16/);

  const cleared = formatIssueBody(evaluateTrend([run(16, { "usage.root": PASSED })]));
  assert.match(cleared, /^Cleared: /);
  assert.doesNotMatch(cleared, /Run: /);
});

test("a downloaded artifact tree is read per profile, run id newest first", (t) => {
  const dir = mkdtempSync(join(tmpdir(), "ios-audit-trend-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const outcome = (screen, types) => ({
    screen,
    test: "testContentFixtureShowsOverview",
    audit_types: ["clipped", "contrast", "dynamic-type", "hit-region", "other"],
    outcomes: types,
    exempted: {},
    first_pass: [],
    second_pass: null,
  });
  for (const id of [1001, 1002]) {
    const outcomes = join(dir, String(id), "ios-screens-outcomes");
    for (const profile of ["light-large", "dark-large"]) {
      mkdirSync(join(outcomes, `ios-screens-${profile}`), { recursive: true });
      writeFileSync(
        join(outcomes, `ios-screens-${profile}`, "audit-outcome.usage.root.json"),
        JSON.stringify(outcome("usage.root", profile === "dark-large" ? TIMED_OUT : PASSED)),
      );
    }
    // Not an audit outcome, and a sibling of the outcomes directory: both are ignored.
    writeFileSync(join(outcomes, "ios-screens-light-large", "manifest.json"), "{}");
    mkdirSync(join(dir, String(id), "ios-screens-shots", "ios-screens-light-large"), {
      recursive: true,
    });
    writeFileSync(join(dir, String(id), "run.json"), JSON.stringify({ created_at: "2026-09-20Z" }));
  }
  // A run whose census job left no outcomes directory at all is eligible for nothing.
  mkdirSync(join(dir, "1003"), { recursive: true });

  const runs = readRunsDir(dir);
  assert.deepEqual(
    runs.map((one) => one.runId),
    ["1003", "1002", "1001"],
  );
  assert.equal(runs[0].outcomes.length, 0);
  assert.equal(runs[1].createdAt, "2026-09-20Z");
  assert.deepEqual(runs[1].outcomes.map((one) => one.profile).sort(), [
    "dark-large",
    "light-large",
  ]);
  const result = evaluateTrend(runs, { n: 2 });
  assert.equal(result.status, "failed");
  assert.equal(result.keys.length, 2);
  assert.equal(result.runs.length, 3);

  mkdirSync(join(dir, "not-a-run-id"));
  assert.throws(() => readRunsDir(dir), /named after its run id/);
  assert.throws(() => readRunsDir(join(dir, "missing")), /cannot be read/);
});

test("CLI reports, writes both files, and exits 1 on a failing key", (t) => {
  const dir = mkdtempSync(join(tmpdir(), "ios-audit-trend-cli-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  for (const id of [2001, 2002, 2003]) {
    const profileDir = join(
      dir,
      "runs",
      String(id),
      "ios-screens-outcomes",
      "ios-screens-dark-large",
    );
    mkdirSync(profileDir, { recursive: true });
    writeFileSync(
      join(profileDir, "audit-outcome.usage.root.json"),
      JSON.stringify({ screen: "usage.root", test: "testScreens", outcomes: TIMED_OUT }),
    );
  }
  const out = join(dir, "dist", "trend.json");
  const body = join(dir, "dist", "issue.md");
  const result = spawnSync(
    process.execPath,
    [script, "--runs-dir", join(dir, "runs"), "--n", "3", "--out", out, "--issue-body", body],
    { encoding: "utf8" },
  );
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stdout, /\*\*1 screen has not completed/);
  const report = JSON.parse(readFileSync(out, "utf8"));
  assert.equal(report.status, "failed");
  assert.equal(report.n, 3);
  assert.equal(report.keys[0].profile, "dark-large");
  assert.match(readFileSync(body, "utf8"), /usage\.root/);

  const missing = spawnSync(process.execPath, [script, "--runs-dir", join(dir, "nope")], {
    encoding: "utf8",
  });
  assert.equal(missing.status, 2);
  assert.match(missing.stderr, /cannot be read/);
  assert.equal(spawnSync(process.execPath, [script], { encoding: "utf8" }).status, 2);
});
