import { USAGE_OTHER_MODEL } from "@gotry-io/quota-protocol";
import {
  MODEL_COLOR_FAMILIES,
  MODEL_COLOR_SHADES,
  type ModelColorFamily,
} from "./tokens.generated.ts";

/**
 * The one model colour assignment every chart on the website uses
 * ([ADR 0064](../../../../docs/decisions/0064-analysis-surfaces-lead-with-model-usage.md)).
 *
 * A model's family is its inference provider; its shade is its rank by tokens inside that
 * provider over the Account's `all` period. Ranks past the family's shades, the folded `other`
 * series, and a model `all` has never seen take `--model-other`. The rank is over all history,
 * not the period on screen, so switching period or page never recolours a model.
 */
type AgentTree = ReadonlyArray<{
  providers: ReadonlyArray<{
    provider: string;
    models: ReadonlyArray<{ model: string; totals: { total_tokens: number } }>;
  }>;
}>;

export type ModelColors = ReadonlyMap<string, string>;

export const OTHER_MODEL_COLOR = "var(--model-other)";

/** The identity a colour, a ledger row, and a river band share: provider and model. */
export function modelKey(provider: string | null, model: string): string {
  return `${provider ?? ""}|${model}`;
}

function family(provider: string): ModelColorFamily {
  return (MODEL_COLOR_FAMILIES as readonly string[]).includes(provider)
    ? (provider as ModelColorFamily)
    : "unknown";
}

/** Rank every model of the Account's `all` tree inside its provider, and name its colour. */
export function modelColors(allAgents: AgentTree): ModelColors {
  const byProvider = new Map<string, Map<string, number>>();
  for (const agent of allAgents) {
    for (const provider of agent.providers) {
      const models = byProvider.get(provider.provider) ?? new Map<string, number>();
      for (const leaf of provider.models) {
        if (leaf.model === USAGE_OTHER_MODEL) continue;
        models.set(leaf.model, (models.get(leaf.model) ?? 0) + leaf.totals.total_tokens);
      }
      byProvider.set(provider.provider, models);
    }
  }
  const colors = new Map<string, string>();
  for (const [provider, models] of byProvider) {
    const ranked = [...models].sort(
      ([leftModel, leftTokens], [rightModel, rightTokens]) =>
        rightTokens - leftTokens || leftModel.localeCompare(rightModel),
    );
    ranked.forEach(([model], index) => {
      colors.set(
        modelKey(provider, model),
        index < MODEL_COLOR_SHADES
          ? `var(--model-${family(provider)}-${index + 1})`
          : OTHER_MODEL_COLOR,
      );
    });
  }
  return colors;
}

export function modelColor(colors: ModelColors, provider: string | null, model: string): string {
  return colors.get(modelKey(provider, model)) ?? OTHER_MODEL_COLOR;
}
