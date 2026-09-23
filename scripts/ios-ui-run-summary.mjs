#!/usr/bin/env node
// What an XCUITest run actually executed, and whether that is the selection CI asked for.
//
// `xcodebuild ... -only-testing:<target>/<class>` exits 0 when the selector matches nothing, so a
// misspelled class, a method without a `test` prefix, or a class removed from the target would read
// as a green required check. A count alone is not enough either: a floor below the real size lets
// methods disappear, and a skipped case would count as one that ran. So with `--expect-methods` the
// selection is checked by identity: every `test…()` method the class's source declares must appear
// in the result exactly as that class, with a result that says it executed (Passed or Failed), and
// nothing else may have run. Failed cases are reported but are not a selection problem — the
// xcodebuild step already fails on them.
//
// Usage: ios-ui-run-summary.mjs <result.xcresult> [--expect-class NAME]
//                                [--expect-methods <Class.swift>] [--min-tests N]
//                                [--title "What ran"]
//
// `--min-tests` is a sanity bound only: it catches a source read that found almost nothing, or an
// unfiltered run (the unit tests, which name no class) that shrank.
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";

/** Results that mean the case executed. Anything else — Skipped, Expected Failure, none — did not. */
const EXECUTED = new Set(["Passed", "Failed"]);

/** Every leaf test case in the result, with the class that owns it. */
function cases(node, suite, found = []) {
  for (const child of node.children ?? []) {
    if (child.nodeType === "Test Case") {
      found.push({
        suite,
        name: child.name ?? "",
        result: child.result ?? "",
        duration: child.duration ?? "",
        failures: (child.children ?? [])
          .filter((one) => one.nodeType === "Failure Message")
          .map((one) => one.name ?? ""),
      });
      continue;
    }
    cases(child, child.nodeType === "Test Suite" ? (child.name ?? suite) : suite, found);
  }
  return found;
}

/**
 * The test methods a Swift XCTest class declares, as xcresulttool names them (`testName()`):
 * instance methods whose name starts with `test` and that take no argument. `private` and
 * `fileprivate` methods are not discovered by XCTest, so they are not expected either.
 */
export function declaredTestMethods(source) {
  const names = new Set();
  const declaration =
    /^[ \t]*((?:@\w+(?:\([^)]*\))?\s+)*)((?:\w+\s+)*)func\s+(test\w*)\s*\(\s*\)/gm;
  for (const match of source.matchAll(declaration)) {
    const modifiers = match[2].split(/\s+/).filter(Boolean);
    if (modifiers.includes("private") || modifiers.includes("fileprivate")) continue;
    if (modifiers.includes("static") || modifiers.includes("class")) continue;
    names.add(`${match[3]}()`);
  }
  return [...names].sort();
}

/** A positive whole number, or an explanation of why the value is not one. */
export function parseMinimum(raw) {
  if (raw === undefined) return { value: 0 };
  if (!/^[1-9]\d*$/.test(raw)) {
    return { error: `--min-tests needs a positive whole number, got ${JSON.stringify(raw)}` };
  }
  return { value: Number(raw) };
}

/** The report and the verdict, from `xcresulttool get test-results tests --format json`. */
export function summarize(
  json,
  { expectedClass, expectedMethods, minimumTests = 0, title = "iOS UI run" } = {},
) {
  const all = [];
  for (const plan of JSON.parse(json).testNodes ?? []) cases(plan, "", all);

  const byClass = new Map();
  for (const one of all) {
    const bucket = byClass.get(one.suite) ?? { total: 0, failed: 0, seconds: 0, names: new Set() };
    bucket.names.add(one.name);
    bucket.total = bucket.names.size;
    if (one.result === "Failed") bucket.failed += 1;
    bucket.seconds += Number.parseFloat(one.duration) || 0;
    byClass.set(one.suite, bucket);
  }

  const lines = [`## ${title}`, ""];
  if (byClass.size === 0) {
    lines.push("No test case ran.");
  } else {
    lines.push("| Class | Tests | Failed | Seconds |", "| --- | ---: | ---: | ---: |");
    for (const [name, bucket] of [...byClass].sort(([a], [b]) => a.localeCompare(b))) {
      // A test that belongs to no suite still ran; name the row rather than leave a blank cell.
      const shown = name === "" ? "(no suite)" : name;
      lines.push(
        `| ${shown} | ${bucket.total} | ${bucket.failed} | ${bucket.seconds.toFixed(1)} |`,
      );
    }
  }
  const failures = all.filter((one) => one.result === "Failed");
  if (failures.length > 0) {
    lines.push("", "### Failures", "");
    for (const one of failures) {
      lines.push(`- \`${one.suite}.${one.name}\` — ${one.failures[0] ?? "no message"}`);
    }
  }

  const problems = [];
  if (expectedClass && !byClass.has(expectedClass)) {
    problems.push(`expected ${expectedClass} to run; the result bundle has no such class`);
  }
  if (expectedClass) {
    const others = [...byClass.keys()].filter((name) => name !== expectedClass);
    if (others.length > 0) {
      const shown = others.map((name) => (name === "" ? "(no suite)" : name)).sort();
      problems.push(`unexpected classes ran: ${shown.join(", ")}`);
    }
  }

  const selected = expectedClass ? all.filter((one) => one.suite === expectedClass) : all;
  // A repeated identity is one method, not two; a count that doubled it would hide a missing one.
  const distinct = new Set(selected.map((one) => `${one.suite}.${one.name}`));
  const duplicated = selected.length - distinct.size;
  if (duplicated > 0) {
    lines.push("", `${duplicated} repeated case(s) counted once.`);
  }

  // Did not execute: skipped, expected-failure, or no result at all. A method that appears twice
  // counts as executed when either appearance executed.
  const executed = new Set(
    selected.filter((one) => EXECUTED.has(one.result)).map((one) => `${one.suite}.${one.name}`),
  );
  const notExecuted = [...distinct].filter((id) => !executed.has(id)).sort();
  if (notExecuted.length > 0) {
    const shown = notExecuted.map((id) => {
      const one = selected.find((each) => `${each.suite}.${each.name}` === id);
      return `${id} (${one?.result || "no result"})`;
    });
    problems.push(`did not execute: ${shown.join(", ")}`);
  }

  if (expectedClass && expectedMethods) {
    const ran = new Set(selected.map((one) => one.name));
    const missing = expectedMethods.filter((name) => !ran.has(name));
    const unknown = [...ran].filter((name) => !expectedMethods.includes(name)).sort();
    if (missing.length > 0) {
      problems.push(`${expectedClass} did not run: ${missing.join(", ")}`);
    }
    if (unknown.length > 0) {
      problems.push(
        `${expectedClass} ran methods its source does not declare: ${unknown.join(", ")}`,
      );
    }
    if (expectedMethods.length < minimumTests) {
      problems.push(
        `the source declares ${expectedMethods.length} test methods, fewer than the floor of ${minimumTests}`,
      );
    }
    lines.push(
      "",
      `Expected ${expectedMethods.length} methods of ${expectedClass}; ` +
        `${executed.size} executed, ${missing.length} missing.`,
    );
  }

  const counted = executed.size;
  if (counted < minimumTests) {
    problems.push(`expected at least ${minimumTests} tests, ran ${counted}`);
  }
  if (problems.length > 0) {
    lines.push("", `**Selection is not what CI asked for:** ${problems.join("; ")}.`);
  }
  return { report: lines.join("\n"), problems, tests: counted, failed: failures.length };
}

const usage =
  "usage: ios-ui-run-summary.mjs <result.xcresult> [--expect-class NAME]" +
  " [--expect-methods FILE.swift] [--min-tests N] [--title TEXT]";

if (import.meta.url === `file://${process.argv[1]}`) {
  const argv = process.argv.slice(2);
  const known = new Set(["--expect-class", "--expect-methods", "--min-tests", "--title"]);
  const options = {};
  let bundle;
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value.startsWith("--")) {
      const next = argv[index + 1];
      if (!known.has(value) || next === undefined || next.startsWith("--")) {
        console.error(`${value}: unknown option or missing value\n${usage}`);
        process.exit(2);
      }
      options[value] = next;
      index += 1;
    } else if (bundle === undefined) {
      bundle = value;
    } else {
      console.error(`unexpected argument ${value}\n${usage}`);
      process.exit(2);
    }
  }
  if (!bundle || !existsSync(bundle)) {
    console.error(usage);
    process.exit(2);
  }
  const minimum = parseMinimum(options["--min-tests"]);
  if (minimum.error) {
    console.error(minimum.error);
    process.exit(2);
  }
  const expectedClass = options["--expect-class"];
  let expectedMethods;
  if (options["--expect-methods"]) {
    if (!expectedClass) {
      console.error("--expect-methods needs --expect-class");
      process.exit(2);
    }
    expectedMethods = declaredTestMethods(readFileSync(options["--expect-methods"], "utf8"));
  }
  const json = execFileSync(
    "xcrun",
    ["xcresulttool", "get", "test-results", "tests", "--path", bundle, "--format", "json"],
    { encoding: "utf8", maxBuffer: 256 * 1024 * 1024 },
  );
  const { report, problems } = summarize(json, {
    expectedClass,
    expectedMethods,
    minimumTests: minimum.value,
    ...(options["--title"] ? { title: options["--title"] } : {}),
  });
  console.log(report);
  if (problems.length > 0) process.exit(1);
}
