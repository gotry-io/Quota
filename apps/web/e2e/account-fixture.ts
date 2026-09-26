import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  AccountUsageActivityResponseReadSchema,
  AccountUsagePeriodResponseReadSchema,
  USAGE_HOUR_GRID_RULE,
} from "@gotry-io/quota-protocol";
import type { Page } from "@playwright/test";
import { parseAccountResponse, parseAccountSummaryBody } from "../src/lib/account-reads.ts";
import {
  ACCOUNT_SETTINGS_PATH,
  defaultAccountSettingsResponse,
} from "../src/lib/account-settings-client.ts";

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

type UsageCacheSaved = {
  amount_microusd: string;
  status: string;
  unpriced_rows: number;
};

type UsagePeriod = {
  totals: UsageTotals;
  cost: UsageCost;
  cache_saved: UsageCacheSaved;
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

export { defaultAccountSettingsResponse };

/** Same-origin Account settings document the Usage budget reads. */
export async function mockAccountSettings(
  page: Page,
  document: ReturnType<typeof defaultAccountSettingsResponse> = defaultAccountSettingsResponse(),
): Promise<void> {
  await page.route(
    (url) => new URL(url).pathname === ACCOUNT_SETTINGS_PATH,
    async (route) => {
      const method = route.request().method();
      if (method === "GET") {
        await route.fulfill({
          status: 200,
          contentType: "application/json",
          headers: {
            ETag: `"${document.revision}"`,
            "Cache-Control": "private, no-cache",
          },
          body: JSON.stringify(document),
        });
        return;
      }
      if (method === "PUT") {
        const posted = JSON.parse(route.request().postData() ?? "{}") as {
          alerts: (typeof document)["alerts"];
          budget: (typeof document)["budget"];
        };
        const next = {
          protocol_version: 2,
          revision: document.revision + 1,
          updated_at: "2026-09-21T10:00:00.000Z",
          alerts: posted.alerts,
          budget: posted.budget,
        };
        await route.fulfill({
          status: 200,
          contentType: "application/json",
          headers: {
            ETag: `"${next.revision}"`,
            "Cache-Control": "private, no-cache",
          },
          body: JSON.stringify(next),
        });
        return;
      }
      await route.fallback();
    },
  );
}

export function accountReadFromSummary(summary: unknown = accountSummary): {
  protocol_version: 2;
  account: unknown;
  identities: { provider: string; label: string | null; linked_at: string }[];
} {
  const body = summary as { account: { account_id: string } };
  const payload = {
    protocol_version: 2 as const,
    account: body.account,
    identities: [{ provider: "github", label: "octocat", linked_at: "2026-01-04T12:00:00Z" }],
  };
  const parsed = parseAccountResponse(200, payload);
  if (parsed.status !== "ok") {
    throw new Error(`accountReadFromSummary failed schema: ${parsed.message}`);
  }
  return parsed.account;
}
accountSummary.usage.today = retoken(accountSummary.usage.last_30_days, 80, 20, "5000");
accountSummary.usage.last_7_days = retoken(accountSummary.usage.last_30_days, 2400, 700, "36900");

const smokeDevices = accountSummary as unknown as {
  devices: Array<{
    id: string;
    display_name: string;
    platform: string;
    last_seen_at: string | null;
    last_observed_at: string | null;
  }>;
};
smokeDevices.devices.push({
  id: "device_2",
  display_name: "Kitchen",
  platform: "macos",
  last_seen_at: "2026-08-10T09:31:00Z",
  last_observed_at: "2026-08-10T09:00:00Z",
});

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

function nextUtcDate(date: string): string {
  const shifted = new Date(`${date}T00:00:00Z`);
  shifted.setUTCDate(shifted.getUTCDate() + 1);
  return shifted.toISOString().slice(0, 10);
}

function inclusiveDays(from: string, to: string): number {
  return (
    Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000) + 1
  );
}

function usageForSpan(summary: AccountSummary, from: string, to: string): UsagePeriod {
  const span = inclusiveDays(from, to);
  if (span === 1) return summary.usage.today;
  if (span === 7) return summary.usage.last_7_days;
  if (span <= 31) return summary.usage.last_30_days;
  return summary.usage.all;
}

function distribute(value: number, n: number): number[] {
  if (n <= 0) return [];
  const base = Math.floor(value / n);
  const parts = Array.from({ length: n }, () => base);
  parts[n - 1] = (parts[n - 1] ?? 0) + (value - base * n);
  return parts;
}

function presentLocalDates(from: string, to: string): string[] {
  const dates = utcDates(from, to);
  if (dates.length < 2) return dates;
  const dropAt = dates.length >= 4 ? 3 : 1;
  return dates.filter((_, index) => index !== dropAt);
}

function periodDays(
  from: string,
  to: string,
  usage: UsagePeriod,
): Array<{ date: string; totals: UsageTotals; cost: UsageCost; partial: boolean }> {
  const dates = presentLocalDates(from, to);
  if (dates.length === 1) {
    const date = dates[0];
    if (date === undefined) return [];
    return [
      {
        date,
        totals: structuredClone(usage.totals),
        cost: structuredClone(usage.cost),
        partial: usage.partial,
      },
    ];
  }
  const n = dates.length;
  const inputs = distribute(usage.totals.input_tokens, n);
  const outputs = distribute(usage.totals.output_tokens, n);
  const cacheReads = distribute(usage.totals.cache_read_input_tokens, n);
  const cacheWrites = distribute(usage.totals.cache_write_input_tokens, n);
  const reasonings = distribute(usage.totals.reasoning_tokens, n);
  const messages = distribute(usage.totals.messages, n);
  const micros = distribute(Number(usage.cost.amount_microusd ?? "0"), n);
  return dates.map((date, index) => {
    const input = inputs[index] ?? 0;
    const output = outputs[index] ?? 0;
    const cacheRead = Math.min(cacheReads[index] ?? 0, input);
    const cacheWrite = Math.min(cacheWrites[index] ?? 0, Math.max(0, input - cacheRead));
    const amount = micros[index] ?? 0;
    return {
      date,
      totals: {
        total_tokens: input + output,
        input_tokens: input,
        output_tokens: output,
        cache_read_input_tokens: cacheRead,
        cache_write_input_tokens: cacheWrite,
        reasoning_tokens: Math.min(reasonings[index] ?? 0, output),
        messages: messages[index] ?? 0,
      },
      cost: {
        ...structuredClone(usage.cost),
        amount_microusd: String(amount),
        calculated_rows: 1,
        reported_rows: 0,
        unpriced_rows: 0,
        status: "complete",
        basis: "calculated",
        unpriced: [],
      },
      partial: usage.partial,
    };
  });
}

type SeriesCell = {
  model: string;
  total_tokens: number;
  input_tokens: number;
  output_tokens: number;
  cache_read_input_tokens: number;
  cache_write_input_tokens: number;
  cost_microusd: string | null;
};

function zeroTotals(): UsageTotals {
  return {
    total_tokens: 0,
    input_tokens: 0,
    output_tokens: 0,
    cache_read_input_tokens: 0,
    cache_write_input_tokens: 0,
    reasoning_tokens: 0,
    messages: 0,
  };
}

/**
 * `model_series` for a period whose days spread each model evenly: the eight largest models by
 * tokens, then `other`, one cell per model and present date.
 */
function modelSeries(dates: readonly string[], agents: UsagePeriod["agents"]) {
  const byModel = new Map<string, { provider: string; totals: UsageTotals; micros: number }>();
  for (const agent of agents) {
    for (const provider of agent.providers) {
      for (const leaf of provider.models) {
        const row = byModel.get(leaf.model) ?? {
          provider: provider.provider,
          totals: zeroTotals(),
          micros: 0,
        };
        row.totals.total_tokens += leaf.totals.total_tokens;
        row.totals.input_tokens += leaf.totals.input_tokens;
        row.totals.output_tokens += leaf.totals.output_tokens;
        row.totals.cache_read_input_tokens += leaf.totals.cache_read_input_tokens;
        row.totals.cache_write_input_tokens += leaf.totals.cache_write_input_tokens;
        row.micros += Number(leaf.cost.amount_microusd ?? "0");
        byModel.set(leaf.model, row);
      }
    }
  }
  const ranked = [...byModel]
    .filter(([, row]) => row.totals.total_tokens > 0)
    .sort(
      ([leftModel, left], [rightModel, right]) =>
        right.totals.total_tokens - left.totals.total_tokens || leftModel.localeCompare(rightModel),
    );
  const legend = ranked.slice(0, 8);
  const rest = ranked.slice(8);
  const n = dates.length;
  const split = (row: { totals: UsageTotals; micros: number }) => ({
    input: distribute(row.totals.input_tokens, n),
    output: distribute(row.totals.output_tokens, n),
    read: distribute(row.totals.cache_read_input_tokens, n),
    write: distribute(row.totals.cache_write_input_tokens, n),
    micros: distribute(row.micros, n),
  });
  const columns = legend.map(([model, row]) => ({ model, parts: split(row) }));
  if (rest.length > 0) {
    const other = { totals: zeroTotals(), micros: 0 };
    for (const [, row] of rest) {
      other.totals.input_tokens += row.totals.input_tokens;
      other.totals.output_tokens += row.totals.output_tokens;
      other.totals.cache_read_input_tokens += row.totals.cache_read_input_tokens;
      other.totals.cache_write_input_tokens += row.totals.cache_write_input_tokens;
      other.micros += row.micros;
    }
    columns.push({ model: "other", parts: split(other) });
  }
  return {
    models: [
      ...legend.map(([model, row]) => ({ model, provider: row.provider })),
      ...(rest.length > 0 ? [{ model: "other", provider: null }] : []),
    ],
    days: dates.map((date, index) => ({
      date,
      partial: false,
      models: columns
        .map(({ model, parts }): SeriesCell => {
          const input = parts.input[index] ?? 0;
          const output = parts.output[index] ?? 0;
          const read = Math.min(parts.read[index] ?? 0, input);
          return {
            model,
            total_tokens: input + output,
            input_tokens: input,
            output_tokens: output,
            cache_read_input_tokens: read,
            cache_write_input_tokens: Math.min(parts.write[index] ?? 0, input - read),
            cost_microusd: String(parts.micros[index] ?? 0),
          };
        })
        .filter((cell) => cell.total_tokens > 0),
    })),
  };
}

export function accountUsagePeriod(
  from: string,
  to: string,
  timezone: string,
  options: { breakdown?: boolean; series?: boolean; summary?: unknown } = {},
): unknown {
  const summary = (options.summary ?? accountSummary) as AccountSummary;
  const usage = usageForSpan(summary, from, to);
  const days = periodDays(from, to, usage);
  const payload = {
    protocol_version: 6,
    request: { from, to, timezone },
    bounds: {
      start: `${from}T00:00:00Z`,
      end: `${nextUtcDate(to)}T00:00:00Z`,
      grid: USAGE_HOUR_GRID_RULE,
    },
    totals: structuredClone(usage.totals),
    cost: structuredClone(usage.cost),
    cache_saved: structuredClone(usage.cache_saved),
    days,
    ...(options.breakdown === true ? { agents: structuredClone(usage.agents) } : {}),
    ...(options.series === true
      ? {
          model_series: modelSeries(
            days.map((day) => day.date),
            usage.agents,
          ),
        }
      : {}),
    coverage: {
      partial: usage.partial,
      daily_retained_from: null,
      hourly_retained_from: null,
      truncated_by_retention: false,
    },
    revision: {
      usage_revision: 1,
      device_generation: 1,
      account_updated_at: "2026-08-12T12:00:00Z",
      pricing_revision: "pricing_1",
      model_catalog_revision: "models_1",
      fold_version: 1,
    },
  };
  const parsed = AccountUsagePeriodResponseReadSchema.safeParse(payload);
  if (!parsed.success) {
    throw new Error(`accountUsagePeriod failed schema: ${parsed.error.message}`);
  }
  return parsed.data;
}

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

/*
 * The screenshot Account: synthetic, never a live capture. Every read below is generated from one
 * table of models, so a period's days add up to its totals, its tree, and its model series, and
 * the summary's periods, the activity year, and the period reads agree with each other.
 */
const STUDIO_DEVICE_ID = "device_visual_studio";
const AIR_DEVICE_ID = "device_visual_air";
const KITCHEN_DEVICE_ID = "device_visual_kitchen";
const PRICING_REVISION = "pricing_visual_fixture";
const DAY_MS = 86_400_000;

type VisualModel = {
  agent: string;
  provider: string;
  model: string;
  /** Tokens on an ordinary weekday. */
  daily: number;
  /** Microdollars per token. */
  price: number;
  cache: number;
  /** Days ago the model first ran, or null for always. */
  since: number | null;
  /** Days ago it stopped carrying its full load, or null. */
  until: number | null;
};

const VISUAL_MODELS: VisualModel[] = [
  {
    agent: "claude_code",
    provider: "anthropic",
    model: "claude-opus-5-5",
    daily: 17_500_000,
    price: 0.35,
    cache: 0.84,
    since: 16,
    until: null,
  },
  {
    agent: "codex",
    provider: "openai",
    model: "gpt-5.6-codex",
    daily: 11_000_000,
    price: 0.22,
    cache: 0.76,
    since: null,
    until: null,
  },
  {
    agent: "claude_code",
    provider: "anthropic",
    model: "claude-sonnet-5",
    daily: 7_400_000,
    price: 0.21,
    cache: 0.82,
    since: null,
    until: null,
  },
  {
    agent: "claude_code",
    provider: "anthropic",
    model: "claude-opus-5",
    daily: 13_000_000,
    price: 0.36,
    cache: 0.83,
    since: null,
    until: 16,
  },
  {
    agent: "opencode",
    provider: "deepseek",
    model: "deepseek-v4",
    daily: 4_600_000,
    price: 0.05,
    cache: 0.88,
    since: null,
    until: null,
  },
  {
    agent: "grok",
    provider: "xai",
    model: "grok-4.5",
    daily: 2_900_000,
    price: 0.23,
    cache: 0.61,
    since: 43,
    until: null,
  },
  {
    agent: "opencode",
    provider: "moonshot",
    model: "kimi-2.6",
    daily: 1_500_000,
    price: 0.09,
    cache: 0.7,
    since: 27,
    until: null,
  },
  {
    agent: "claude_code",
    provider: "anthropic",
    model: "claude-haiku-4-5",
    daily: 1_400_000,
    price: 0.07,
    cache: 0.79,
    since: null,
    until: null,
  },
  {
    agent: "codex",
    provider: "openai",
    model: "gpt-5.5-mini",
    daily: 1_000_000,
    price: 0.05,
    cache: 0.72,
    since: null,
    until: null,
  },
  {
    agent: "opencode",
    provider: "anthropic",
    model: "claude-sonnet-5",
    daily: 600_000,
    price: 0.21,
    cache: 0.8,
    since: null,
    until: null,
  },
  {
    agent: "gemini",
    provider: "google",
    model: "gemini-3-pro",
    daily: 450_000,
    price: 0.12,
    cache: 0.55,
    since: null,
    until: null,
  },
];

function isoFrom(now: number, deltaMs: number): string {
  return new Date(now + deltaMs).toISOString().replace(/\.\d+Z$/, "Z");
}

function localToday(): string {
  const now = new Date();
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`;
}

function daysAgo(date: string): number {
  return Math.round(
    (Date.parse(`${localToday()}T00:00:00Z`) - Date.parse(`${date}T00:00:00Z`)) / DAY_MS,
  );
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
  for (let instant = start; instant <= end; instant += DAY_MS) {
    dates.push(new Date(instant).toISOString().slice(0, 10));
  }
  return dates;
}

function cost(microusd: number, rows: number): UsageCost {
  return {
    mode: "auto",
    basis: "calculated",
    status: "complete",
    amount_microusd: String(Math.round(microusd)),
    catalog_revision: PRICING_REVISION,
    calculated_rows: rows,
    reported_rows: 0,
    unpriced_rows: 0,
    assumptions: ["agent_default_channel"],
    unpriced: [],
  };
}

type VisualLeaf = { spec: VisualModel; totals: UsageTotals; microusd: number };

/** One model's day: a weekday rhythm, a slow wave, per-model noise, and one quiet day. */
function visualLeaf(spec: VisualModel, date: string): VisualLeaf | null {
  const ago = daysAgo(date);
  if (ago < 0 || ago === 19) return null;
  if (spec.since !== null && ago > spec.since) return null;
  const weekday = new Date(`${date}T00:00:00Z`).getUTCDay();
  const weekend = weekday === 0 || weekday === 6 ? 0.32 : 1;
  const wave = 1 + 0.35 * Math.sin(ago / 3.3);
  const noise = 0.6 + ((daySeed(`${date}${spec.model}${spec.agent}`) % 1000) / 1000) * 0.8;
  const fading = spec.until !== null && ago <= spec.until ? 0.06 : 1;
  const today = ago === 0 ? 0.55 : 1;
  const tokens = Math.round(spec.daily * weekend * wave * noise * fading * today);
  if (tokens <= 0) return null;
  const output = Math.round(tokens * 0.11);
  const input = tokens - output;
  const cacheRead = Math.round(input * spec.cache);
  const cacheWrite = Math.min(Math.round(input * 0.05), input - cacheRead);
  return {
    spec,
    totals: {
      total_tokens: tokens,
      input_tokens: input,
      output_tokens: output,
      cache_read_input_tokens: cacheRead,
      cache_write_input_tokens: cacheWrite,
      reasoning_tokens: Math.round(output * 0.26),
      messages: Math.max(1, Math.round(tokens / 190_000)),
    },
    microusd: tokens * spec.price,
  };
}

function addInto(into: UsageTotals, from: UsageTotals): void {
  into.total_tokens += from.total_tokens;
  into.input_tokens += from.input_tokens;
  into.output_tokens += from.output_tokens;
  into.cache_read_input_tokens += from.cache_read_input_tokens;
  into.cache_write_input_tokens += from.cache_write_input_tokens;
  into.reasoning_tokens += from.reasoning_tokens;
  into.messages += from.messages;
}

function visualPeriod(dates: readonly string[]) {
  const totals = zeroTotals();
  let microusd = 0;
  let saved = 0;
  const leaves = new Map<string, VisualLeaf>();
  const days: Array<{ date: string; leaves: VisualLeaf[]; totals: UsageTotals; microusd: number }> =
    [];
  for (const date of dates) {
    const dayLeaves = VISUAL_MODELS.map((spec) => visualLeaf(spec, date)).filter(
      (leaf): leaf is VisualLeaf => leaf !== null,
    );
    if (dayLeaves.length === 0) continue;
    const dayTotals = zeroTotals();
    let dayMicros = 0;
    for (const leaf of dayLeaves) {
      addInto(dayTotals, leaf.totals);
      dayMicros += leaf.microusd;
      saved += leaf.totals.cache_read_input_tokens * leaf.spec.price * 0.9;
      const key = `${leaf.spec.agent}|${leaf.spec.provider}|${leaf.spec.model}`;
      const merged = leaves.get(key) ?? { spec: leaf.spec, totals: zeroTotals(), microusd: 0 };
      addInto(merged.totals, leaf.totals);
      merged.microusd += leaf.microusd;
      leaves.set(key, merged);
    }
    addInto(totals, dayTotals);
    microusd += dayMicros;
    days.push({ date, leaves: dayLeaves, totals: dayTotals, microusd: dayMicros });
  }
  const agents: UsagePeriod["agents"] = [];
  for (const leaf of leaves.values()) {
    let agent = agents.find((item) => item.agent === leaf.spec.agent);
    if (!agent) {
      agent = { agent: leaf.spec.agent, providers: [] };
      agents.push(agent);
    }
    let provider = agent.providers.find((item) => item.provider === leaf.spec.provider);
    if (!provider) {
      provider = { provider: leaf.spec.provider, models: [] };
      agent.providers.push(provider);
    }
    provider.models.push({
      model: leaf.spec.model,
      totals: leaf.totals,
      cost: cost(leaf.microusd, leaf.totals.messages),
    });
  }
  const period: UsagePeriod = {
    totals,
    cost: cost(microusd, totals.messages),
    cache_saved: {
      amount_microusd: String(Math.round(saved)),
      status: "complete",
      unpriced_rows: 0,
    },
    partial: false,
    agents,
  };
  return { period, days };
}

function localDatesBack(count: number): { from: string; to: string } {
  const to = localToday();
  const from = new Date(Date.parse(`${to}T00:00:00Z`) - (count - 1) * DAY_MS)
    .toISOString()
    .slice(0, 10);
  return { from, to };
}

function visualWindow(
  input: {
    id: string;
    title: string;
    used_percent: number;
    resets_in_ms: number;
    duration_seconds?: number;
    primary_cadence?: "five_hour" | "weekly" | "monthly";
    remaining_value?: number;
    limit_value?: number;
    value_unit?: "usd" | "credits" | "count";
  },
  now: number,
) {
  return {
    id: input.id,
    title: input.title,
    used_percent: input.used_percent,
    resets_at: isoFrom(now, input.resets_in_ms),
    ...(input.duration_seconds === undefined ? {} : { duration_seconds: input.duration_seconds }),
    ...(input.primary_cadence === undefined ? {} : { primary_cadence: input.primary_cadence }),
    ...(input.remaining_value === undefined ? {} : { remaining_value: input.remaining_value }),
    ...(input.limit_value === undefined ? {} : { limit_value: input.limit_value }),
    ...(input.value_unit === undefined ? {} : { value_unit: input.value_unit }),
  };
}

function visualSubscription(input: {
  provider: string;
  fingerprint: string;
  label: string;
  plan: string;
  device: string;
  observed_at: string;
  status?: string;
  windows: unknown[];
}) {
  return {
    key: `${input.provider}|${input.fingerprint}|global|`,
    provider: input.provider,
    snapshot: {
      provider: input.provider,
      account: {
        fingerprint: input.fingerprint,
        fingerprint_scope: "global",
        label: input.label,
        plan: input.plan,
      },
      windows: input.windows,
      status: input.status ?? "available",
      observed_at: input.observed_at,
    },
    sources: [{ device_id: input.device, observed_at: input.observed_at }],
  };
}

const HOUR = 3_600_000;

/** Homepage and account-page shots: a marketing-grade synthetic Account. */
export function screenshotAccountSummary(): unknown {
  const now = Date.now();
  const payload = {
    protocol_version: 6,
    account: {
      account_id: "account_visual_octocat",
      display_label: "octocat",
      created_at: isoFrom(now, -400 * DAY_MS),
    },
    devices: [
      {
        id: STUDIO_DEVICE_ID,
        display_name: "Studio Mac",
        platform: "macos",
        last_seen_at: isoFrom(now, -40_000),
        last_observed_at: isoFrom(now, -60_000),
      },
      {
        id: AIR_DEVICE_ID,
        display_name: "MacBook Air",
        platform: "macos",
        last_seen_at: isoFrom(now, -150_000),
        last_observed_at: isoFrom(now, -180_000),
      },
      {
        id: KITCHEN_DEVICE_ID,
        display_name: "Kitchen Mac",
        platform: "macos",
        last_seen_at: isoFrom(now, -2 * DAY_MS),
        last_observed_at: isoFrom(now, -2 * DAY_MS),
      },
    ],
    subscriptions: [
      visualSubscription({
        provider: "claude",
        fingerprint: "visual_claude",
        label: "pe***@example.com",
        plan: "Max 20x",
        device: STUDIO_DEVICE_ID,
        observed_at: isoFrom(now, -60_000),
        windows: [
          visualWindow(
            {
              id: "five_hour",
              title: "5 Hours",
              used_percent: 29,
              resets_in_ms: 3.2 * HOUR,
              duration_seconds: 18_000,
              primary_cadence: "five_hour",
            },
            now,
          ),
          visualWindow(
            {
              id: "weekly",
              title: "Weekly",
              used_percent: 62,
              resets_in_ms: 3.6 * 24 * HOUR,
              duration_seconds: 604_800,
              primary_cadence: "weekly",
            },
            now,
          ),
          visualWindow(
            {
              id: "weekly_opus",
              title: "Weekly Opus",
              used_percent: 36,
              resets_in_ms: 3.6 * 24 * HOUR,
              duration_seconds: 604_800,
            },
            now,
          ),
        ],
      }),
      visualSubscription({
        provider: "codex",
        fingerprint: "visual_codex",
        label: "pe***@example.com",
        plan: "Pro",
        device: AIR_DEVICE_ID,
        observed_at: isoFrom(now, -180_000),
        windows: [
          visualWindow(
            {
              id: "five_hour",
              title: "5 Hours",
              used_percent: 8,
              resets_in_ms: 4.66 * HOUR,
              duration_seconds: 18_000,
              primary_cadence: "five_hour",
            },
            now,
          ),
          visualWindow(
            {
              id: "weekly",
              title: "Weekly",
              used_percent: 88,
              resets_in_ms: 2.1 * 24 * HOUR,
              duration_seconds: 604_800,
              primary_cadence: "weekly",
            },
            now,
          ),
        ],
      }),
      visualSubscription({
        provider: "cursor",
        fingerprint: "visual_cursor",
        label: "octocat",
        plan: "Pro",
        device: STUDIO_DEVICE_ID,
        observed_at: isoFrom(now, -240_000),
        windows: [
          visualWindow(
            {
              id: "other_models",
              title: "Other Models",
              used_percent: 64,
              resets_in_ms: 6.5 * 24 * HOUR,
              duration_seconds: 2_592_000,
              primary_cadence: "monthly",
            },
            now,
          ),
          visualWindow(
            {
              id: "included",
              title: "Included Usage",
              used_percent: 72.75,
              resets_in_ms: 6.5 * 24 * HOUR,
              duration_seconds: 2_592_000,
              remaining_value: 5.45,
              limit_value: 20,
              value_unit: "usd",
            },
            now,
          ),
        ],
      }),
      visualSubscription({
        provider: "copilot",
        fingerprint: "visual_copilot",
        label: "octocat",
        plan: "Pro+",
        device: STUDIO_DEVICE_ID,
        observed_at: isoFrom(now, -360_000),
        windows: [
          visualWindow(
            {
              id: "premium",
              title: "Premium Requests",
              used_percent: 18,
              resets_in_ms: 5.2 * 24 * HOUR,
              duration_seconds: 2_592_000,
              primary_cadence: "monthly",
            },
            now,
          ),
        ],
      }),
      visualSubscription({
        provider: "openrouter",
        fingerprint: "visual_openrouter",
        label: "sk-or-…7f2",
        plan: "pay_as_you_go",
        device: STUDIO_DEVICE_ID,
        observed_at: isoFrom(now, -120_000),
        windows: [
          {
            id: "balance",
            title: "Balance",
            used_percent: 0,
            remaining_value: 23.41,
            value_unit: "usd",
          },
        ],
      }),
      visualSubscription({
        provider: "kimi",
        fingerprint: "visual_kimi",
        label: "+86 ••• 4410",
        plan: "Andante",
        device: KITCHEN_DEVICE_ID,
        observed_at: isoFrom(now, -2 * DAY_MS),
        status: "auth_required",
        windows: [
          visualWindow(
            {
              id: "weekly",
              title: "Weekly",
              used_percent: 45,
              resets_in_ms: 2 * 24 * HOUR,
              duration_seconds: 604_800,
            },
            now,
          ),
        ],
      }),
    ],
    usage: {
      today: visualPeriod(utcDates(localToday(), localToday())).period,
      last_7_days: visualPeriod(utcDates(localDatesBack(7).from, localToday())).period,
      last_30_days: visualPeriod(utcDates(localDatesBack(30).from, localToday())).period,
      all: visualPeriod(utcDates(localDatesBack(365).from, localToday())).period,
    },
    pricing_revision: PRICING_REVISION,
    model_catalog_revision: "models_visual_fixture",
    collection_requested_at: null,
  };
  const parsed = parseAccountSummaryBody(payload);
  if (!parsed) {
    throw new Error("screenshotAccountSummary failed schema");
  }
  return parsed;
}

/** A period read over the screenshot Account, with the tree and the series when asked. */
export function screenshotAccountUsagePeriod(
  from: string,
  to: string,
  timezone: string,
  options: { breakdown?: boolean; series?: boolean } = {},
): unknown {
  const { period, days } = visualPeriod(utcDates(from, to));
  const merged = new Map<string, { provider: string; tokens: number }>();
  for (const day of days) {
    for (const leaf of day.leaves) {
      const row = merged.get(leaf.spec.model) ?? { provider: leaf.spec.provider, tokens: 0 };
      row.tokens += leaf.totals.total_tokens;
      merged.set(leaf.spec.model, row);
    }
  }
  const ranked = [...merged].sort(
    ([leftModel, left], [rightModel, right]) =>
      right.tokens - left.tokens || leftModel.localeCompare(rightModel),
  );
  const legend = ranked.slice(0, 8).map(([model]) => model);
  const hasOther = ranked.length > 8;
  const today = localToday();
  const series = {
    models: [
      ...ranked.slice(0, 8).map(([model, row]) => ({ model, provider: row.provider })),
      ...(hasOther ? [{ model: "other", provider: null }] : []),
    ],
    days: days.map((day) => {
      const cells = new Map<string, SeriesCell & { priced: number }>();
      for (const leaf of day.leaves) {
        const model = legend.includes(leaf.spec.model) ? leaf.spec.model : "other";
        const cell = cells.get(model) ?? {
          model,
          total_tokens: 0,
          input_tokens: 0,
          output_tokens: 0,
          cache_read_input_tokens: 0,
          cache_write_input_tokens: 0,
          cost_microusd: "0",
          priced: 0,
        };
        cell.total_tokens += leaf.totals.total_tokens;
        cell.input_tokens += leaf.totals.input_tokens;
        cell.output_tokens += leaf.totals.output_tokens;
        cell.cache_read_input_tokens += leaf.totals.cache_read_input_tokens;
        cell.cache_write_input_tokens += leaf.totals.cache_write_input_tokens;
        cell.priced += leaf.microusd;
        cells.set(model, cell);
      }
      return {
        date: day.date,
        partial: day.date === today,
        models: [...legend, "other"]
          .map((model) => cells.get(model))
          .filter((cell): cell is SeriesCell & { priced: number } => cell !== undefined)
          .map(({ priced, ...cell }) => ({ ...cell, cost_microusd: String(Math.round(priced)) })),
      };
    }),
  };
  const payload = {
    protocol_version: 6,
    request: { from, to, timezone },
    bounds: {
      start: `${from}T00:00:00Z`,
      end: `${nextUtcDate(to)}T00:00:00Z`,
      grid: USAGE_HOUR_GRID_RULE,
    },
    totals: period.totals,
    cost: period.cost,
    cache_saved: period.cache_saved,
    days: days.map((day) => ({
      date: day.date,
      totals: day.totals,
      cost: cost(day.microusd, day.totals.messages),
      partial: day.date === today,
    })),
    ...(options.breakdown === true ? { agents: period.agents } : {}),
    ...(options.series === true ? { model_series: series } : {}),
    coverage: {
      partial: false,
      daily_retained_from: null,
      hourly_retained_from: null,
      truncated_by_retention: false,
    },
    revision: {
      usage_revision: 1,
      device_generation: 1,
      account_updated_at: isoFrom(Date.now(), -60_000),
      pricing_revision: PRICING_REVISION,
      model_catalog_revision: "models_visual_fixture",
      fold_version: 1,
    },
  };
  const parsed = AccountUsagePeriodResponseReadSchema.safeParse(payload);
  if (!parsed.success) {
    throw new Error(`screenshotAccountUsagePeriod failed schema: ${parsed.error.message}`);
  }
  return parsed.data;
}

export function screenshotAccountActivity(from: string, to: string, detailed = false): unknown {
  const days = utcDates(from, to).flatMap((date) => {
    const { period, days: generated } = visualPeriod([date]);
    if (generated.length === 0) return [];
    return [
      {
        date,
        totals: period.totals,
        cost: period.cost,
        partial: false,
        ...(detailed ? { agents: period.agents } : {}),
      },
    ];
  });
  const payload = { protocol_version: 6, days };
  const parsed = AccountUsageActivityResponseReadSchema.safeParse(payload);
  if (!parsed.success) {
    throw new Error(`screenshotAccountActivity failed schema: ${parsed.error.message}`);
  }
  return parsed.data;
}

const hourWeights = [0, 0, 0, 0, 0, 0, 0, 1, 3, 6, 8, 9, 7, 8, 11, 12, 12, 10, 7, 6, 5, 4, 2, 1];

export function screenshotAccountRhythm(from: string, to: string): unknown {
  const days = screenshotAccountActivity(from, to) as {
    protocol_version: number;
    days: Array<{ date: string; totals: { total_tokens: number } }>;
  };
  const total = days.days.reduce((sum, day) => sum + day.totals.total_tokens, 0);
  const sum = hourWeights.reduce((left, right) => left + right, 0);
  const hours_of_day = hourWeights.map((weight, hour) => ({
    hour,
    total_tokens: sum > 0 ? Math.floor((total * weight) / sum) : 0,
    cost_microusd: null as string | null,
  }));
  const weekdayWeights = [0.15, 1, 1.6, 1.05, 0.95, 0.55, 0.2];
  const weekday_hours = weekdayWeights.map((weight) =>
    hours_of_day.map((hour) => Math.floor((hour.total_tokens * weight) / 7)),
  );
  const payload = { ...days, hours_of_day, weekday_hours };
  const parsed = AccountUsageActivityResponseReadSchema.safeParse(payload);
  if (!parsed.success) {
    throw new Error(`screenshotAccountRhythm failed schema: ${parsed.error.message}`);
  }
  return parsed.data;
}

export function screenshotAccountActivityDay(date: string): unknown {
  return screenshotAccountActivity(date, date, true);
}

/** Account quota history for the screenshot Account's weekly windows, one bucket every six hours. */
export function screenshotQuotaHistory(provider: string): unknown {
  const summary = screenshotAccountSummary() as {
    subscriptions: Array<{
      provider: string;
      snapshot: {
        windows: Array<{
          id: string;
          used_percent: number;
          resets_at?: string;
          duration_seconds?: number;
        }>;
      };
    }>;
  };
  const now = Date.now();
  const windows: Record<string, { duration_seconds: number; points: unknown[] }> = {};
  const subscription = summary.subscriptions.find((item) => item.provider === provider);
  for (const window of subscription?.snapshot.windows ?? []) {
    if (!window.resets_at || !window.duration_seconds || window.duration_seconds < 86_400) continue;
    const end = Date.parse(window.resets_at);
    const start = end - window.duration_seconds * 1_000;
    const points = [];
    for (let at = start; at < now - HOUR; at += 6 * HOUR) {
      const progress = (at - start) / (now - start);
      const wobble = ((daySeed(String(at)) % 100) / 100 - 0.5) * 4;
      points.push({
        resets_at: window.resets_at,
        bucket_start: new Date(at).toISOString().replace(/\.\d+Z$/, "Z"),
        used_percent: Math.max(0, Math.min(100, window.used_percent * progress ** 0.9 + wobble)),
      });
    }
    windows[window.id] = { duration_seconds: window.duration_seconds, points };
  }
  return { protocol_version: 6, sync: true, windows };
}
