import { MODEL_CATALOG } from "@gotry-io/quota-protocol";
import { describe, expect, it, vi } from "vitest";
import type { RelayAppOptions } from "../src/app.ts";
import { PRICING_CATALOG } from "../src/pricing-catalog.ts";

const validations = vi.hoisted(() => ({
  pricing: vi.fn(),
  model: vi.fn(),
}));

vi.mock("@gotry-io/quota-model", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@gotry-io/quota-model")>();
  return {
    ...actual,
    validatePricingCatalog(...input: Parameters<typeof actual.validatePricingCatalog>) {
      validations.pricing();
      return actual.validatePricingCatalog(...input);
    },
    validateModelCatalog(...input: Parameters<typeof actual.validateModelCatalog>) {
      validations.model();
      return actual.validateModelCatalog(...input);
    },
  };
});

const { createRelayApp } = await import("../src/app.ts");

function appOptions(): RelayAppOptions {
  return {
    state: {} as RelayAppOptions["state"],
    usageState: {} as RelayAppOptions["usageState"],
    accountService: {} as RelayAppOptions["accountService"],
    webAuth: {} as RelayAppOptions["webAuth"],
    hasher: {} as RelayAppOptions["hasher"],
  };
}

describe("Relay catalog initialization", () => {
  it("trusts checked-in defaults and still validates each injected catalog", () => {
    expect(validations.pricing).not.toHaveBeenCalled();
    expect(validations.model).not.toHaveBeenCalled();

    createRelayApp(appOptions());
    createRelayApp(appOptions());
    expect(validations.pricing).not.toHaveBeenCalled();
    expect(validations.model).not.toHaveBeenCalled();

    createRelayApp({ ...appOptions(), pricingCatalog: { ...PRICING_CATALOG } });
    createRelayApp({ ...appOptions(), pricingCatalog: { ...PRICING_CATALOG } });
    expect(validations.pricing).toHaveBeenCalledTimes(2);
    expect(validations.model).not.toHaveBeenCalled();

    createRelayApp({ ...appOptions(), modelCatalog: { ...MODEL_CATALOG } });
    createRelayApp({ ...appOptions(), modelCatalog: { ...MODEL_CATALOG } });
    expect(validations.pricing).toHaveBeenCalledTimes(2);
    expect(validations.model).toHaveBeenCalledTimes(2);
  });
});
