import conformanceJson from "../fixtures/usage-export-conformance.json" with { type: "json" };
import { describe, expect, it } from "vitest";

type CellKind = "text" | "number";

type CellCase = {
  name: string;
  input: string;
  kind: CellKind;
  expected: string;
};

type PeriodInput = {
  scope: string;
  from: string;
  to: string;
  timezone: string;
  bounds: { start: string; end: string; grid: string } | null;
  cost_basis: string;
  coverage: { partial: boolean; truncated_by_retention: boolean };
  revision: Record<string, unknown> | null;
  exported_at: string;
  app_version: string;
  days: Array<{
    date: string;
    totals: Record<string, number>;
    cost: { amount_microusd: string | null; status: string };
  }>;
};

type PeriodCase = {
  name: string;
  input: PeriodInput;
  expected_csv: string;
  expected_json: {
    days: Array<{ date: string; api_equivalent_cost: string | null; cost_status: string }>;
  };
};

const conformance = conformanceJson as unknown as {
  csv_header: string;
  csv_cell_cases: CellCase[];
  cases: PeriodCase[];
};

const required = ["missing_and_unpriced", "partial_cost_and_this_mac"] as const;

describe("usage export conformance", () => {
  it("names the CSV header, cell cases, and every required period case", () => {
    expect(conformance.csv_header).toBe(
      "date,total tokens,input,output,cache read,cache write,reasoning,messages,API-equivalent cost,cost status",
    );
    expect(conformance.csv_cell_cases.map((item) => item.name)).toEqual([
      "formula_equals",
      "formula_plus",
      "formula_minus",
      "formula_at",
      "formula_tab",
      "formula_cr",
      "comma",
      "quotes",
      "plain",
      "empty",
      "number",
      "decimal",
      "negative_number",
    ]);
    expect(conformance.cases.map((item) => item.name)).toEqual([...required]);
  });
});
