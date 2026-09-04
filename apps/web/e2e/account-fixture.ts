import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

type WireCase = { name: string; accepted: boolean; payload: unknown };
type WireConformance = { contracts: { account_summary: WireCase[] } };

type UsageTotals = {
  total_tokens: number;
  input_tokens: number;
  output_tokens: number;
  cache_read_input_tokens: number;
  cache_write_input_tokens: number;
  reasoning_tokens: number;
  messages: number;
};

type UsageCost = {
  mode: string;
  basis: string;
  status: string;
  amount_microusd: string;
  catalog_revision: string;
  calculated_rows: number;
  reported_rows: number;
  unpriced_rows: number;
  assumptions: string[];
  unpriced: unknown[];
};

type UsagePeriod = {
  totals: UsageTotals;
  cost: UsageCost;
  partial: boolean;
  agents: Array<{
    agent: string;
    providers: Array<{
      provider: string;
      models: Array<{
        model: string;
        totals: UsageTotals;
        cost: UsageCost;
      }>;
    }>;
  }>;
};

type AccountSummary = {
  usage: {
    today: UsagePeriod;
    last_7_days: UsagePeriod;
    last_30_days: UsagePeriod;
    all: UsagePeriod;
  };
};

const conformance = JSON.parse(
  readFileSync(
    join(
      dirname(fileURLToPath(import.meta.url)),
      "../../../packages/protocol/fixtures/wire-conformance.json",
    ),
    "utf8",
  ),
) as WireConformance;

const accepted = conformance.contracts.account_summary.find((testCase) => testCase.accepted);
if (!accepted) {
  throw new Error("wire-conformance.json has no accepted account_summary");
}

function retoken(
  period: UsagePeriod,
  input: number,
  output: number,
  microusd: string,
): UsagePeriod {
  const next = structuredClone(period);
  next.totals.input_tokens = input;
  next.totals.output_tokens = output;
  next.totals.total_tokens = input + output;
  next.totals.cache_read_input_tokens = 0;
  next.totals.cache_write_input_tokens = 0;
  next.totals.reasoning_tokens = 0;
  next.cost.amount_microusd = microusd;
  for (const agent of next.agents) {
    for (const provider of agent.providers) {
      for (const model of provider.models) {
        model.totals.input_tokens = input;
        model.totals.output_tokens = output;
        model.totals.total_tokens = input + output;
        model.totals.cache_read_input_tokens = 0;
        model.totals.cache_write_input_tokens = 0;
        model.totals.reasoning_tokens = 0;
        model.cost.amount_microusd = microusd;
      }
    }
  }
  return next;
}

export const accountSummary = structuredClone(accepted.payload) as AccountSummary;
accountSummary.usage.today = retoken(accountSummary.usage.last_30_days, 80, 20, "5000");
accountSummary.usage.last_7_days = retoken(accountSummary.usage.last_30_days, 2400, 700, "36900");

const thirtyDayProvider = accountSummary.usage.last_30_days.agents[0]?.providers[0];
const thirtyDaySeed = thirtyDayProvider?.models[0];
if (!thirtyDayProvider || !thirtyDaySeed) {
  throw new Error("wire-conformance.json account_summary is missing a 30-day model leaf");
}
for (let n = 2; n <= 6; n += 1) {
  thirtyDayProvider.models.push({
    ...structuredClone(thirtyDaySeed),
    model: `gpt-fold-${n}`,
  });
}

const today = accountSummary.usage.today;
export const accountActivity = {
  protocol_version: 6,
  days: [
    {
      date: "2026-08-12",
      totals: structuredClone(today.totals),
      cost: structuredClone(today.cost),
      partial: false,
    },
  ],
};
