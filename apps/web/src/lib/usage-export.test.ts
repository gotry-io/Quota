import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, it } from "vitest";
import {
  csvCell,
  usageExportCsv,
  usageExportFilename,
  usageExportJson,
  type UsageExportInput,
} from "./usage-export.ts";

type CellKind = "text" | "number";

const fixture = JSON.parse(
  readFileSync(
    join(
      dirname(fileURLToPath(import.meta.url)),
      "../../../../packages/protocol/fixtures/usage-export-conformance.json",
    ),
    "utf8",
  ),
) as {
  csv_cell_cases: Array<{ name: string; input: string; kind: CellKind; expected: string }>;
  cases: Array<{
    name: string;
    input: UsageExportInput;
    expected_csv: string;
    expected_json: ReturnType<typeof usageExportJson>;
  }>;
};

it("answers every CSV cell case in the shared fixture", () => {
  for (const testCase of fixture.csv_cell_cases) {
    expect(csvCell(testCase.input, testCase.kind), testCase.name).toBe(testCase.expected);
  }
});

it("answers every period case in the shared fixture", () => {
  for (const testCase of fixture.cases) {
    expect(usageExportCsv(testCase.input), `${testCase.name} csv`).toBe(testCase.expected_csv);
    expect(usageExportJson(testCase.input), `${testCase.name} json`).toEqual(
      testCase.expected_json,
    );
  }
});

it("names the download from the asked local dates", () => {
  expect(usageExportFilename("2026-08-10", "2026-08-12", "csv")).toBe(
    "quota-usage-2026-08-10-2026-08-12.csv",
  );
  expect(usageExportFilename("2026-08-10", "2026-08-12", "json")).toBe(
    "quota-usage-2026-08-10-2026-08-12.json",
  );
});
