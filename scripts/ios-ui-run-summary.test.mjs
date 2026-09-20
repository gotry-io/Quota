import assert from "node:assert/strict";
import test from "node:test";
import { summarize } from "./ios-ui-run-summary.mjs";

/** The shape `xcresulttool get test-results tests --format json` returns, trimmed to what matters. */
const result = (cases) =>
  JSON.stringify({
    testNodes: [
      {
        children: [
          {
            nodeType: "Test Suite",
            name: "QuotaSmokeUITests",
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

test("a selection that matched nothing is a problem, not a pass", () => {
  const { problems } = summarize(result([]), {
    expectedClass: "QuotaSmokeUITests",
    minimumTests: 10,
  });
  assert.equal(problems.length, 2);
  assert.match(problems[0], /no such class/);
});

test("a class that ran fewer tests than the floor is a problem", () => {
  const { problems } = summarize(result([["testA()", "Passed", 1]]), {
    expectedClass: "QuotaSmokeUITests",
    minimumTests: 5,
  });
  assert.deepEqual(problems, ["expected at least 5 tests, ran 1"]);
});
