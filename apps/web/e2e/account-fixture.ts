import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  AccountSummaryReadSchema,
  AccountUsageActivityResponseReadSchema,
} from "@gotry-io/quota-protocol";

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

export function accountActivityDay(date: string) {
  return {
    protocol_version: 6,
    days: [
      {
        date,
        totals: structuredClone(today.totals),
        cost: structuredClone(today.cost),
        partial: false,
        agents: structuredClone(today.agents),
      },
    ],
  };
}

const STUDIO_DEVICE_ID = "device_visual_studio";
const KITCHEN_DEVICE_ID = "device_visual_kitchen";
const PRICING_REVISION = "pricing_visual_fixture";
const THIRTY_DAY_TOKENS = 11_400_000;
const THIRTY_DAY_MICROUSD = 8_500_000;
const OPENAI_THIRTY_DAY_MODELS = [
  { model: "gpt-5.6-sol", tokens: 3_200_000, cost: 2_385_965, messages: 236 },
  { model: "gpt-5.5", tokens: 2_400_000, cost: 1_789_474, messages: 177 },
  { model: "gpt-5", tokens: 1_900_000, cost: 1_416_667, messages: 140 },
  { model: "o3", tokens: 1_400_000, cost: 1_043_860, messages: 103 },
  { model: "o4-mini", tokens: 1_100_000, cost: 820_175, messages: 81 },
  { model: "gpt-4.1", tokens: 850_000, cost: 633_772, messages: 63 },
  { model: "gpt-5-codex", tokens: 550_000, cost: 410_087, messages: 42 },
] as const;

function isoFrom(now: number, deltaMs: number): string {
  return new Date(now + deltaMs).toISOString();
}

function totals(input: number, output: number, messages: number): UsageTotals {
  const cacheRead = Math.min(input, Math.floor(input * 0.22));
  const cacheWrite = Math.min(input - cacheRead, Math.floor(input * 0.02));
  const reasoning = Math.min(output, Math.floor(output * 0.18));
  return {
    total_tokens: input + output,
    input_tokens: input,
    output_tokens: output,
    cache_read_input_tokens: cacheRead,
    cache_write_input_tokens: cacheWrite,
    reasoning_tokens: reasoning,
    messages,
  };
}

function splitTokens(total: number): { input: number; output: number } {
  const input = Math.floor(total * 0.85);
  return { input, output: total - input };
}

function cost(microusd: number, rows: number): UsageCost {
  return {
    mode: "auto",
    basis: "calculated",
    status: "complete",
    amount_microusd: String(microusd),
    catalog_revision: PRICING_REVISION,
    calculated_rows: rows,
    reported_rows: 0,
    unpriced_rows: 0,
    assumptions: ["agent_default_channel"],
    unpriced: [],
  };
}

function openaiModels(
  rows: ReadonlyArray<{ model: string; tokens: number; cost: number; messages: number }>,
): UsagePeriod["agents"][number]["providers"][number]["models"] {
  return rows.map((row) => {
    const parts = splitTokens(row.tokens);
    return {
      model: row.model,
      totals: totals(parts.input, parts.output, row.messages),
      cost: cost(row.cost, row.messages),
    };
  });
}

function periodFromModels(
  rows: ReadonlyArray<{ model: string; tokens: number; cost: number; messages: number }>,
): UsagePeriod {
  const models = openaiModels(rows);
  const input = models.reduce((sum, model) => sum + model.totals.input_tokens, 0);
  const output = models.reduce((sum, model) => sum + model.totals.output_tokens, 0);
  const messages = models.reduce((sum, model) => sum + model.totals.messages, 0);
  const microusd = models.reduce((sum, model) => sum + Number(model.cost.amount_microusd), 0);
  const merged = totals(input, output, messages);
  return {
    totals: merged,
    cost: cost(microusd, messages),
    partial: false,
    agents: [
      {
        agent: "codex",
        providers: [{ provider: "openai", models }],
      },
    ],
  };
}

function scaleModels(
  factor: number,
): Array<{ model: string; tokens: number; cost: number; messages: number }> {
  return OPENAI_THIRTY_DAY_MODELS.map((row, index) => {
    const last = index === OPENAI_THIRTY_DAY_MODELS.length - 1;
    const tokens = last
      ? Math.round(THIRTY_DAY_TOKENS * factor) -
        OPENAI_THIRTY_DAY_MODELS.slice(0, -1).reduce(
          (sum, item) => sum + Math.round(item.tokens * factor),
          0,
        )
      : Math.round(row.tokens * factor);
    const microusd = last
      ? Math.round(THIRTY_DAY_MICROUSD * factor) -
        OPENAI_THIRTY_DAY_MODELS.slice(0, -1).reduce(
          (sum, item) => sum + Math.round(item.cost * factor),
          0,
        )
      : Math.round(row.cost * factor);
    return {
      model: row.model,
      tokens,
      cost: microusd,
      messages: Math.max(1, Math.round(row.messages * factor)),
    };
  });
}

function snapshot(input: {
  provider: "codex" | "claude" | "grok";
  fingerprint: string;
  label?: string;
  plan: string;
  windows: Array<{
    id: string;
    title: string;
    used_percent: number;
    resets_at: string;
    duration_seconds?: number;
    primary_cadence?: "five_hour" | "weekly" | "monthly";
  }>;
  observed_at: string;
}) {
  return {
    provider: input.provider,
    account: {
      fingerprint: input.fingerprint,
      fingerprint_scope: "global" as const,
      ...(input.label === undefined ? {} : { label: input.label }),
      plan: input.plan,
    },
    windows: input.windows.map((window) => ({
      id: window.id,
      title: window.title,
      used_percent: window.used_percent,
      resets_at: window.resets_at,
      ...(window.duration_seconds === undefined
        ? {}
        : { duration_seconds: window.duration_seconds }),
      ...(window.primary_cadence === undefined ? {} : { primary_cadence: window.primary_cadence }),
    })),
    status: "available",
    observed_at: input.observed_at,
  };
}

function subscription(
  input: Parameters<typeof snapshot>[0] & { observed_at: string; kitchen_observed_at: string },
) {
  const body = snapshot(input);
  return {
    key: `${input.provider}|${input.fingerprint}|global|`,
    provider: input.provider,
    snapshot: body,
    sources: [
      { device_id: STUDIO_DEVICE_ID, observed_at: input.observed_at },
      { device_id: KITCHEN_DEVICE_ID, observed_at: input.kitchen_observed_at },
    ],
  };
}

/** Homepage shots: marketing-grade synthetic account, never a live capture. */
export function screenshotAccountSummary(): unknown {
  const now = Date.now();
  const studioSeen = isoFrom(now, -45_000);
  const studioObserved = isoFrom(now, -90_000);
  const kitchenSeen = isoFrom(now, -2 * 3_600_000);
  const kitchenObserved = isoFrom(now, -2.2 * 3_600_000);
  const thirtyDay = periodFromModels(OPENAI_THIRTY_DAY_MODELS);
  const sevenDay = periodFromModels(scaleModels(0.28));
  const todayPeriod = periodFromModels([
    { model: "gpt-5.6-sol", tokens: 1_204_620, cost: 1_052_000, messages: 116 },
    { model: "gpt-5.5", tokens: 500_000, cost: 437_234, messages: 48 },
  ]);
  const allPeriod = periodFromModels(scaleModels(1.64));

  const payload = {
    protocol_version: 6,
    account: {
      account_id: "account_visual_octocat",
      display_label: "octocat",
      created_at: isoFrom(now, -30 * 86_400_000),
    },
    devices: [
      {
        id: STUDIO_DEVICE_ID,
        display_name: "Studio Mac",
        platform: "macos",
        last_seen_at: studioSeen,
        last_observed_at: studioObserved,
      },
      {
        id: KITCHEN_DEVICE_ID,
        display_name: "Kitchen Mac",
        platform: "macos",
        last_seen_at: kitchenSeen,
        last_observed_at: kitchenObserved,
      },
    ],
    subscriptions: [
      subscription({
        provider: "codex",
        fingerprint: "visual_codex",
        label: "pe***@example.com",
        plan: "Plus",
        observed_at: studioObserved,
        kitchen_observed_at: kitchenObserved,
        windows: [
          {
            id: "five_hour",
            title: "5 Hours",
            used_percent: 32,
            resets_at: isoFrom(now, 2_700_000),
            duration_seconds: 18_000,
            primary_cadence: "five_hour",
          },
          {
            id: "weekly",
            title: "Weekly",
            used_percent: 16,
            resets_at: isoFrom(now, 4 * 86_400_000),
            duration_seconds: 604_800,
            primary_cadence: "weekly",
          },
        ],
      }),
      subscription({
        provider: "claude",
        fingerprint: "visual_claude",
        label: "Team workspace",
        plan: "Max",
        observed_at: isoFrom(now, -120_000),
        kitchen_observed_at: kitchenObserved,
        windows: [
          {
            id: "five_hour",
            title: "5 Hours",
            used_percent: 47,
            resets_at: isoFrom(now, 7_200_000),
            duration_seconds: 18_000,
            primary_cadence: "five_hour",
          },
        ],
      }),
      subscription({
        provider: "grok",
        fingerprint: "visual_grok",
        label: "Account 1",
        plan: "SuperGrok",
        observed_at: isoFrom(now, -180_000),
        kitchen_observed_at: kitchenObserved,
        windows: [
          {
            id: "monthly",
            title: "Monthly",
            used_percent: 73,
            resets_at: isoFrom(now, 12 * 86_400_000),
            primary_cadence: "monthly",
          },
        ],
      }),
    ],
    usage: {
      today: todayPeriod,
      last_7_days: sevenDay,
      last_30_days: thirtyDay,
      all: allPeriod,
    },
    pricing_revision: PRICING_REVISION,
    model_catalog_revision: "models_visual_fixture",
  };

  const parsed = AccountSummaryReadSchema.safeParse(payload);
  if (!parsed.success) {
    throw new Error(`screenshotAccountSummary failed schema: ${parsed.error.message}`);
  }
  return parsed.data;
}

function daySeed(date: string): number {
  let hash = 2166136261;
  for (const char of date) {
    hash ^= char.charCodeAt(0);
    hash = Math.imul(hash, 16777619);
  }
  return hash >>> 0;
}

function utcDates(from: string, to: string): string[] {
  const dates: string[] = [];
  const start = Date.parse(`${from}T00:00:00Z`);
  const end = Date.parse(`${to}T00:00:00Z`);
  for (let instant = start; instant <= end; instant += 86_400_000) {
    dates.push(new Date(instant).toISOString().slice(0, 10));
  }
  return dates;
}

function activityDay(date: string, detailed: boolean) {
  const seed = daySeed(date);
  const weekday = new Date(`${date}T00:00:00Z`).getUTCDay();
  const weekend = weekday === 0 || weekday === 6;
  const pulse = seed % 10;
  if (weekend ? pulse > 1 : pulse === 2 || pulse === 6) {
    return null;
  }
  const tokens = 18_000 + (seed % 220_000);
  const parts = splitTokens(tokens);
  const messages = 4 + (seed % 28);
  const microusd = 8_000 + (seed % 90_000);
  const body = {
    date,
    totals: totals(parts.input, parts.output, messages),
    cost: cost(microusd, messages),
    partial: false,
  };
  if (!detailed) return body;
  const model = OPENAI_THIRTY_DAY_MODELS[seed % OPENAI_THIRTY_DAY_MODELS.length];
  return {
    ...body,
    agents: [
      {
        agent: "codex",
        providers: [
          {
            provider: "openai",
            models: [
              {
                model: model?.model ?? "gpt-5.6-sol",
                totals: body.totals,
                cost: body.cost,
              },
            ],
          },
        ],
      },
    ],
  };
}

export function screenshotAccountActivity(from: string, to: string, detailed = false): unknown {
  const days = utcDates(from, to)
    .map((date) => activityDay(date, detailed))
    .filter((day): day is NonNullable<typeof day> => day !== null);
  const payload = { protocol_version: 6, days };
  const parsed = AccountUsageActivityResponseReadSchema.safeParse(payload);
  if (!parsed.success) {
    throw new Error(`screenshotAccountActivity failed schema: ${parsed.error.message}`);
  }
  return parsed.data;
}

export function screenshotAccountActivityDay(date: string): unknown {
  const generated = activityDay(date, true);
  const payload = {
    protocol_version: 6,
    days: [
      generated ?? {
        date,
        totals: totals(80, 20, 1),
        cost: cost(5000, 1),
        partial: false,
        agents: [
          {
            agent: "codex",
            providers: [
              {
                provider: "openai",
                models: [
                  {
                    model: "gpt-5.6-sol",
                    totals: totals(80, 20, 1),
                    cost: cost(5000, 1),
                  },
                ],
              },
            ],
          },
        ],
      },
    ],
  };
  const parsed = AccountUsageActivityResponseReadSchema.safeParse(payload);
  if (!parsed.success) {
    throw new Error(`screenshotAccountActivityDay failed schema: ${parsed.error.message}`);
  }
  return parsed.data;
}
