#!/usr/bin/env node
// What an XCUITest run actually executed, and whether that is the selection CI asked for.
//
// `xcodebuild ... -only-testing:<target>/<class>` exits 0 when the selector matches nothing, so a
// misspelled class, a method without a `test` prefix, or a class removed from the target would read
// as a green required check. This prints the per-class outcome for a job summary and fails when the
// expected class is missing or ran fewer tests than the floor.
//
// Usage: ios-ui-run-summary.mjs <result.xcresult> [--expect-class NAME] [--min-tests N]
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";

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

/** The report and the verdict, from `xcresulttool get test-results tests --format json`. */
export function summarize(json, { expectedClass, minimumTests = 0 } = {}) {
  const all = [];
  for (const plan of JSON.parse(json).testNodes ?? []) cases(plan, "", all);

  const byClass = new Map();
  for (const one of all) {
    const bucket = byClass.get(one.suite) ?? { total: 0, failed: 0, seconds: 0 };
    bucket.total += 1;
    if (one.result && one.result !== "Passed") bucket.failed += 1;
    bucket.seconds += Number.parseFloat(one.duration) || 0;
    byClass.set(one.suite, bucket);
  }

  const lines = ["## iOS UI run", ""];
  if (byClass.size === 0) {
    lines.push("No test case ran.");
  } else {
    lines.push("| Class | Tests | Failed | Seconds |", "| --- | ---: | ---: | ---: |");
    for (const [name, bucket] of [...byClass].sort(([a], [b]) => a.localeCompare(b))) {
      lines.push(`| ${name} | ${bucket.total} | ${bucket.failed} | ${bucket.seconds.toFixed(1)} |`);
    }
  }
  const failures = all.filter((one) => one.result && one.result !== "Passed");
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
  const counted = expectedClass ? (byClass.get(expectedClass)?.total ?? 0) : all.length;
  if (counted < minimumTests) {
    problems.push(`expected at least ${minimumTests} tests, ran ${counted}`);
  }
  if (problems.length > 0) {
    lines.push("", `**Selection is not what CI asked for:** ${problems.join("; ")}.`);
  }
  return { report: lines.join("\n"), problems, tests: counted, failed: failures.length };
}

const argv = process.argv.slice(2);
const bundle = argv.find((value) => !value.startsWith("--"));
const option = (name) => {
  const index = argv.indexOf(name);
  return index === -1 ? undefined : argv[index + 1];
};
const expectedClass = option("--expect-class");
const minimumTests = Number(option("--min-tests") ?? 0);

if (import.meta.url === `file://${process.argv[1]}`) {
  if (!bundle || !existsSync(bundle)) {
    console.error(
      "usage: ios-ui-run-summary.mjs <result.xcresult> [--expect-class NAME] [--min-tests N]",
    );
    process.exit(2);
  }
  const json = execFileSync(
    "xcrun",
    ["xcresulttool", "get", "test-results", "tests", "--path", bundle, "--format", "json"],
    { encoding: "utf8", maxBuffer: 256 * 1024 * 1024 },
  );
  const { report, problems } = summarize(json, { expectedClass, minimumTests });
  console.log(report);
  if (problems.length > 0) process.exit(1);
}
