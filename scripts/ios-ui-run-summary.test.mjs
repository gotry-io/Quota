import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { declaredTestMethods, parseMinimum, summarize } from "./ios-ui-run-summary.mjs";

/** The shape `xcresulttool get test-results tests --format json` returns, trimmed to what matters. */
const result = (cases, suite = "QuotaSmokeUITests") =>
  JSON.stringify({
    testNodes: [
      {
        children: [
          {
            nodeType: "Test Suite",
            name: suite,
            children: cases.map(([name, outcome, seconds, message]) => ({
              nodeType: "Test Case",
              name,
              result: outcome,
              duration: `${seconds}s`,
              children: message ? [{ nodeType: "Failure Message", name: message }] : [],
            })),
          },
        ],
      },
    ],
  });

/** Two classes in one bundle, as an unfiltered or mis-filtered run would produce. */
const twoClasses = (smoke, screen) => {
  const one = JSON.parse(result(smoke));
  const other = JSON.parse(result(screen, "QuotaScreenUITests"));
  one.testNodes[0].children.push(other.testNodes[0].children[0]);
  return JSON.stringify(one);
};

const expected = ["testA()", "testB()", "testC()"];

test("counts the tests of each class and names the failures", () => {
  const { report, problems, tests, failed } = summarize(
    result([
      ["testA()", "Passed", 2],
      ["testB()", "Failed", 3, "QuotaSmokeUITests.swift:10: XCTAssertTrue failed - devices.root"],
    ]),
    { expectedClass: "QuotaSmokeUITests", minimumTests: 2 },
  );
  assert.equal(tests, 2);
  assert.equal(failed, 1);
  assert.deepEqual(problems, []);
  assert.match(report, /\| QuotaSmokeUITests \| 2 \| 1 \| 5\.0 \|/);
  assert.match(report, /devices\.root/);
});

test("every expected method ran: no problem, and the report says how many", () => {
  const { problems, report } = summarize(
    result([
      ["testA()", "Passed", 1],
      ["testB()", "Failed", 1, "boom"],
      ["testC()", "Passed", 1],
    ]),
    { expectedClass: "QuotaSmokeUITests", expectedMethods: expected, minimumTests: 3 },
  );
  assert.deepEqual(problems, []);
  assert.match(report, /Expected 3 methods of QuotaSmokeUITests; 3 executed, 0 missing/);
});

test("a selection that matched nothing is a problem, not a pass", () => {
  const { problems } = summarize(result([]), {
    expectedClass: "QuotaSmokeUITests",
    expectedMethods: expected,
    minimumTests: 3,
  });
  assert.match(problems[0], /no such class/);
  assert.ok(problems.some((one) => /did not run: testA\(\), testB\(\), testC\(\)/.test(one)));
  assert.ok(problems.some((one) => /expected at least 3 tests, ran 0/.test(one)));
});

test("a partial selection names the methods that did not run, even above the floor", () => {
  const { problems } = summarize(
    result([
      ["testA()", "Passed", 1],
      ["testC()", "Passed", 1],
    ]),
    { expectedClass: "QuotaSmokeUITests", expectedMethods: expected, minimumTests: 1 },
  );
  assert.deepEqual(problems, ["QuotaSmokeUITests did not run: testB()"]);
});

test("a skipped or result-less case did not execute and is a problem", () => {
  const { problems, tests } = summarize(
    result([
      ["testA()", "Passed", 1],
      ["testB()", "Skipped", 0],
      ["testC()", "", 0],
    ]),
    { expectedClass: "QuotaSmokeUITests", expectedMethods: expected },
  );
  assert.equal(tests, 1);
  assert.deepEqual(problems, [
    "did not execute: QuotaSmokeUITests.testB() (Skipped), QuotaSmokeUITests.testC() (no result)",
  ]);
});

test("an expected failure is not an execution the gate accepts", () => {
  const { problems } = summarize(result([["testA()", "Expected Failure", 1]]), {
    expectedClass: "QuotaSmokeUITests",
  });
  assert.deepEqual(problems, ["did not execute: QuotaSmokeUITests.testA() (Expected Failure)"]);
});

test("a repeated identity counts once, so it cannot stand in for a missing method", () => {
  const { problems, tests, report } = summarize(
    result([
      ["testA()", "Passed", 1],
      ["testA()", "Passed", 1],
      ["testB()", "Passed", 1],
    ]),
    { expectedClass: "QuotaSmokeUITests", expectedMethods: expected, minimumTests: 3 },
  );
  assert.equal(tests, 2);
  assert.match(report, /1 repeated case\(s\) counted once/);
  assert.match(report, /\| QuotaSmokeUITests \| 2 \|/);
  assert.deepEqual(problems, [
    "QuotaSmokeUITests did not run: testC()",
    "expected at least 3 tests, ran 2",
  ]);
});

test("a method the source does not declare is named", () => {
  const { problems } = summarize(
    result([
      ["testA()", "Passed", 1],
      ["testB()", "Passed", 1],
      ["testC()", "Passed", 1],
      ["testRenamed()", "Passed", 1],
    ]),
    { expectedClass: "QuotaSmokeUITests", expectedMethods: expected },
  );
  assert.deepEqual(problems, [
    "QuotaSmokeUITests ran methods its source does not declare: testRenamed()",
  ]);
});

test("another class in the selection is a problem", () => {
  const { problems } = summarize(
    twoClasses(
      [
        ["testA()", "Passed", 1],
        ["testB()", "Passed", 1],
        ["testC()", "Passed", 1],
      ],
      [["testScreen()", "Passed", 1]],
    ),
    { expectedClass: "QuotaSmokeUITests", expectedMethods: expected },
  );
  assert.deepEqual(problems, ["unexpected classes ran: QuotaScreenUITests"]);
});

test("a source that declares fewer methods than the floor is a problem", () => {
  const { problems } = summarize(result([["testA()", "Passed", 1]]), {
    expectedClass: "QuotaSmokeUITests",
    expectedMethods: ["testA()"],
    minimumTests: 5,
  });
  assert.deepEqual(problems, [
    "the source declares 1 test methods, fewer than the floor of 5",
    "expected at least 5 tests, ran 1",
  ]);
});

test("a class that ran fewer tests than the floor is a problem", () => {
  const { problems } = summarize(result([["testA()", "Passed", 1]]), {
    expectedClass: "QuotaSmokeUITests",
    minimumTests: 5,
  });
  assert.deepEqual(problems, ["expected at least 5 tests, ran 1"]);
});

test("a suite-less test is named rather than left blank, and the title is the caller's", () => {
  const { report } = summarize(
    JSON.stringify({
      testNodes: [
        {
          nodeType: "Test Plan",
          children: [{ nodeType: "Test Case", name: "loose()", result: "Passed", duration: "1s" }],
        },
      ],
    }),
    { title: "iOS unit run" },
  );
  assert.match(report, /## iOS unit run/);
  assert.match(report, /\| \(no suite\) \| 1 \|/);
});

test("the declared methods are the discoverable test methods of the source", () => {
  const source = `
final class QuotaSmokeUITests: QuotaUITestCase {
  func testOne() throws {}
  func testTwo() {}
  @MainActor func testThree() async throws {}
  private func testHelper() {}
  fileprivate func testOther() {}
  func testWithArgument(_ value: Int) {}
  static func testStatic() {}
  func helper() {}
  // func testCommentedOut() {}
}
`;
  assert.deepEqual(declaredTestMethods(source), ["testOne()", "testThree()", "testTwo()"]);
});

test("the real UI test sources declare the methods the lanes expect", () => {
  const smoke = declaredTestMethods(
    readFileSync(new URL("../apps/ios/UITests/QuotaSmokeUITests.swift", import.meta.url), "utf8"),
  );
  const screen = declaredTestMethods(
    readFileSync(new URL("../apps/ios/UITests/QuotaScreenUITests.swift", import.meta.url), "utf8"),
  );
  assert.ok(smoke.length >= 10, `smoke declares ${smoke.length}`);
  assert.ok(screen.length >= 30, `census declares ${screen.length}`);
  assert.deepEqual(
    smoke.filter((name) => screen.includes(name)),
    [],
    "no method name is in both classes",
  );
});

test("the floor must be a positive whole number", () => {
  assert.deepEqual(parseMinimum(undefined), { value: 0 });
  assert.deepEqual(parseMinimum("16"), { value: 16 });
  for (const bad of ["", "0", "-3", "1.5", "ten", "10x"]) {
    assert.match(parseMinimum(bad).error, /positive whole number/, bad);
  }
});

test("the command refuses an invalid floor or an unknown option before reading a bundle", () => {
  const dir = mkdtempSync(join(tmpdir(), "ios-ui-run-summary-"));
  const bundle = join(dir, "run.xcresult");
  writeFileSync(bundle, "");
  const script = new URL("./ios-ui-run-summary.mjs", import.meta.url).pathname;
  for (const args of [
    [bundle, "--min-tests", "ten"],
    [bundle, "--min-tests"],
    [bundle, "--expect-methods", "x.swift"],
    [bundle, "--unknown", "1"],
  ]) {
    let status = 0;
    try {
      execFileSync(process.execPath, [script, ...args], { stdio: "pipe" });
    } catch (error) {
      status = error.status;
    }
    assert.equal(status, 2, args.join(" "));
  }
  rmSync(dir, { recursive: true, force: true });
});
