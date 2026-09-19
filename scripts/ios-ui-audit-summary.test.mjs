import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  isAuditOutcomeName,
  parseOutcomeJson,
  recordsFromAttachments,
  summarizeOutcomes,
} from "./ios-ui-audit-summary.mjs";

const root = dirname(fileURLToPath(import.meta.url));
const fixturePath = join(root, "ios-ui-audit-summary.fixture.json");
const script = join(root, "ios-ui-audit-summary.mjs");
const fixtureText = readFileSync(fixturePath, "utf8");

test("fixture JSON parses into one record per screen audit", () => {
  const records = parseOutcomeJson(fixtureText, fixturePath);
  assert.equal(records.length, 3);
  assert.equal(records[0].screen, "overview.root");
  assert.equal(records[0].outcomes.contrast, "unconfirmed");
  assert.equal(records[1].outcomes.clipped, "incomplete");
  assert.equal(records[2].outcomes.clipped, "confirmed");
});

test("nil-element and exempted findings are kept on the record", () => {
  const [overview] = parseOutcomeJson(fixtureText, fixturePath);
  const dispositions = overview.first_pass.map((finding) => finding.disposition);
  assert.deepEqual(dispositions, ["recorded", "nil-element", "exempted"]);
  assert.equal(overview.exempted["nil-element"], 1);
  assert.equal(overview.exempted["dynamic-type-subscription-card"], 1);
  assert.equal(overview.exempted["section-header-footer"], 2);
});

test("attachments that are not audit-outcome.* are ignored", () => {
  const records = recordsFromAttachments([
    { name: "overview-content.png", text: "not-json" },
    { name: "audit-unconfirmed-overview.root.txt", text: "legacy" },
    { name: "audit-outcome.overview.root", text: fixtureText },
  ]);
  assert.equal(records.length, 3);
  assert.equal(isAuditOutcomeName("audit-outcome.settings.root.json"), true);
  assert.equal(isAuditOutcomeName("contrast-audit-timeout-usage.root"), false);
});

test("summary totals, per-screen table, and contrast advisory", () => {
  const markdown = summarizeOutcomes(parseOutcomeJson(fixtureText, fixturePath));
  assert.match(
    markdown,
    /Screens audited: 3\. clipped: 1 passed \/ 1 confirmed \/ 0 unconfirmed \/ 1 incomplete\./,
  );
  assert.match(markdown, /contrast: 1 passed \/ 0 confirmed \/ 1 unconfirmed \/ 1 incomplete\./);
  assert.match(
    markdown,
    /Exemptions: dynamic-type-done 1, dynamic-type-form-label 3, dynamic-type-identifier-prefix 4, dynamic-type-subscription-card 1, nil-element 1, overview-today 1, section-header-footer 2\./,
  );
  assert.match(
    markdown,
    /\| overview\.root \| testContentFixtureShowsOverview \| passed \| passed \| passed \| passed \|/,
  );
  assert.match(
    markdown,
    /\| settings\.root \| testContentFixtureShowsSettingsDestinations \| confirmed \| unconfirmed \| passed \| passed \|/,
  );
  assert.match(
    markdown,
    /\| usage\.root \| testContentFixtureShowsOverview \| incomplete \| incomplete \| incomplete \| incomplete \|/,
  );
  assert.match(markdown, /### Contrast \(advisory\)/);
  assert.match(markdown, /Contrast never gates/);
  assert.match(
    markdown,
    /\| overview\.root \| testContentFixtureShowsOverview \| unconfirmed \| 1 \| — \|/,
  );
  assert.doesNotMatch(markdown, /\| Screen \| Test \| clipped \| contrast \|/);
});

test("CLI prints the fixture summary without an xcresult", () => {
  const result = spawnSync(process.execPath, [script, fixturePath], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Screens audited: 3\./);
  assert.match(result.stdout, /### Contrast \(advisory\)/);
});

test("unknown outcome classes are refused", () => {
  assert.throws(
    () =>
      parseOutcomeJson(
        JSON.stringify({
          screen: "overview.root",
          test: "testFoo",
          outcomes: { clipped: "skipped" },
        }),
      ),
    /unknown outcome/,
  );
});
