import { expect, it } from "vitest";
import { modelColor, modelColors } from "./model-colors.ts";

function leaf(model: string, tokens: number) {
  return { model, totals: { total_tokens: tokens } };
}

it("ranks a model inside its own provider over all history, and past the fourth shade is other", () => {
  const colors = modelColors([
    {
      providers: [
        {
          provider: "anthropic",
          models: [
            leaf("a1", 900),
            leaf("a2", 800),
            leaf("a3", 700),
            leaf("a4", 600),
            leaf("a5", 500),
          ],
        },
        { provider: "openai", models: [leaf("o1", 10)] },
        { provider: "somebody-new", models: [leaf("n1", 5)] },
      ],
    },
    // The same model through a second agent adds to its rank rather than taking a second colour.
    { providers: [{ provider: "anthropic", models: [leaf("a4", 400)] }] },
  ]);
  expect(modelColor(colors, "anthropic", "a4")).toBe("var(--model-anthropic-1)");
  expect(modelColor(colors, "anthropic", "a1")).toBe("var(--model-anthropic-2)");
  expect(modelColor(colors, "anthropic", "a5")).toBe("var(--model-other)");
  expect(modelColor(colors, "openai", "o1")).toBe("var(--model-openai-1)");
  expect(modelColor(colors, "somebody-new", "n1")).toBe("var(--model-unknown-1)");
  expect(modelColor(colors, "anthropic", "never-seen")).toBe("var(--model-other)");
  expect(modelColor(colors, null, "other")).toBe("var(--model-other)");
});
