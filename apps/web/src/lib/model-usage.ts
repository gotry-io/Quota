import { USAGE_OTHER_MODEL } from "@gotry-io/quota-protocol";
import { modelKey } from "./model-colors.ts";

/**
 * A period's agent tree read the way the analysis pages show it: one row per model, merged
 * across the agents that sent to it, with the agents named on the row
 * ([ADR 0064](../../../../docs/decisions/0064-analysis-surfaces-lead-with-model-usage.md)).
 *
 * These take the fields they read rather than a whole contract type, because a reader may be
 * shown a member this build has never heard of. See ADR 0023.
 */
export type TotalsView = {
  total_tokens: number;
  input_tokens: number;
  output_tokens: number;
  cache_read_input_tokens: number;
  cache_write_input_tokens: number;
  reasoning_tokens: number;
  messages: number;
};

type CostView = { amount_microusd: string | null; status: string };

export type AgentTreeView = ReadonlyArray<{
  agent: string;
  providers: ReadonlyArray<{
    provider: string;
    models: ReadonlyArray<{ model: string; totals: TotalsView; cost: CostView }>;
  }>;
}>;

export type ModelCost = {
  amount_microusd: string | null;
  status: "complete" | "partial" | "unavailable";
};

export type ModelRow = {
  key: string;
  provider: string;
  model: string;
  /** The agents that sent tokens to this model, most tokens first. */
  agents: Array<{ agent: string; tokens: number }>;
  totals: TotalsView;
  cost: ModelCost;
};

function emptyTotals(): TotalsView {
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

function addTotals(into: TotalsView, from: TotalsView): void {
  into.total_tokens += from.total_tokens;
  into.input_tokens += from.input_tokens;
  into.output_tokens += from.output_tokens;
  into.cache_read_input_tokens += from.cache_read_input_tokens;
  into.cache_write_input_tokens += from.cache_write_input_tokens;
  into.reasoning_tokens += from.reasoning_tokens;
  into.messages += from.messages;
}

/**
 * Cost across leaves: a sum of what was priced, `complete` only when every leaf was, and
 * unavailable when none was. A partial sum is a lower bound, which `formatCost` marks.
 */
export function mergeCosts(costs: readonly CostView[]): ModelCost {
  let sum = 0n;
  let priced = 0;
  let complete = true;
  for (const cost of costs) {
    if (cost.amount_microusd !== null) {
      sum += BigInt(cost.amount_microusd);
      priced += 1;
    }
    if (cost.status !== "complete") complete = false;
  }
  if (priced === 0) return { amount_microusd: null, status: "unavailable" };
  return { amount_microusd: sum.toString(), status: complete ? "complete" : "partial" };
}

/** One row per `(provider, model)`, merged across agents, largest first. */
export function foldModelRows(agents: AgentTreeView): ModelRow[] {
  const rows = new Map<string, ModelRow & { costs: CostView[] }>();
  for (const agent of agents) {
    for (const provider of agent.providers) {
      for (const leaf of provider.models) {
        const key = modelKey(provider.provider, leaf.model);
        const row = rows.get(key) ?? {
          key,
          provider: provider.provider,
          model: leaf.model,
          agents: [],
          totals: emptyTotals(),
          cost: { amount_microusd: null, status: "unavailable" },
          costs: [],
        };
        addTotals(row.totals, leaf.totals);
        row.costs.push(leaf.cost);
        const sent = row.agents.find((item) => item.agent === agent.agent);
        if (sent) sent.tokens += leaf.totals.total_tokens;
        else row.agents.push({ agent: agent.agent, tokens: leaf.totals.total_tokens });
        rows.set(key, row);
      }
    }
  }
  return [...rows.values()]
    .map(({ costs, ...row }) => ({
      ...row,
      cost: mergeCosts(costs),
      agents: row.agents.sort((left, right) => right.tokens - left.tokens),
    }))
    .filter((row) => row.totals.total_tokens > 0)
    .sort(
      (left, right) =>
        right.totals.total_tokens - left.totals.total_tokens ||
        left.model.localeCompare(right.model),
    );
}

export type ShareChange = { kind: "none" } | { kind: "new" } | { kind: "points"; points: number };

/**
 * A row's share against the same model's share of the previous period, in whole points. A model
 * the previous period did not have is **New**; with no previous period there is nothing to say.
 */
export function shareChange(
  row: Pick<ModelRow, "key" | "totals">,
  total: number,
  previous: readonly ModelRow[] | null,
): ShareChange {
  if (previous === null || total <= 0) return { kind: "none" };
  const previousTotal = previous.reduce((sum, item) => sum + item.totals.total_tokens, 0);
  const before = previous.find((item) => item.key === row.key)?.totals.total_tokens ?? 0;
  if (before <= 0 || previousTotal <= 0) return { kind: "new" };
  const points = Math.round((row.totals.total_tokens / total - before / previousTotal) * 100);
  return { kind: "points", points };
}

/** The named models the period ran, leaving out the folded `other` leaf. */
export function namedModelCount(rows: readonly ModelRow[]): number {
  return rows.filter((row) => row.model !== USAGE_OTHER_MODEL).length;
}

/** What each input and output part is of the period's tokens, 0…1. Reasoning is inside output. */
export type TokenMix = {
  cacheRead: number;
  cacheWrite: number;
  freshInput: number;
  output: number;
  /** Reasoning as a share of output. */
  reasoningOfOutput: number;
};

export function tokenMix(totals: TotalsView): TokenMix | null {
  const whole = totals.total_tokens;
  if (whole <= 0) return null;
  const fresh = Math.max(
    0,
    totals.input_tokens - totals.cache_read_input_tokens - totals.cache_write_input_tokens,
  );
  return {
    cacheRead: totals.cache_read_input_tokens / whole,
    cacheWrite: totals.cache_write_input_tokens / whole,
    freshInput: fresh / whole,
    output: totals.output_tokens / whole,
    reasoningOfOutput:
      totals.output_tokens > 0 ? totals.reasoning_tokens / totals.output_tokens : 0,
  };
}

export type AgentModelFlow = {
  agents: Array<{ agent: string; tokens: number }>;
  models: ModelRow[];
  links: Array<{ agent: string; key: string; tokens: number }>;
};

/**
 * Which agent sent how many tokens to which of the period's largest models. Pairs that reach a
 * model outside the top `limit` are left out on both sides, so the two columns add up.
 */
export function agentModelFlow(rows: readonly ModelRow[], limit = 8): AgentModelFlow {
  const models = rows.slice(0, limit);
  const totals = new Map<string, number>();
  const links: AgentModelFlow["links"] = [];
  for (const row of models) {
    for (const sent of row.agents) {
      if (sent.tokens <= 0) continue;
      links.push({ agent: sent.agent, key: row.key, tokens: sent.tokens });
      totals.set(sent.agent, (totals.get(sent.agent) ?? 0) + sent.tokens);
    }
  }
  const agents = [...totals]
    .map(([agent, tokens]) => ({ agent, tokens }))
    .sort((left, right) => right.tokens - left.tokens);
  return { agents, models, links };
}

/** Cost per message in micro-USD, or null when unpriced or nothing was sent. */
export function costPerMessageMicrousd(row: Pick<ModelRow, "cost" | "totals">): number | null {
  if (row.cost.amount_microusd === null || row.totals.messages <= 0) return null;
  return Number(row.cost.amount_microusd) / row.totals.messages;
}
