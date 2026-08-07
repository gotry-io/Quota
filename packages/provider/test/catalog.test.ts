import { PROVIDER_IDS } from "@gotry-io/quota-protocol";
import { describe, expect, it } from "vitest";
import {
  authRequiredMessage,
  configurableProviderIds,
  PROVIDER_CATALOG,
  PROVIDER_ORDER,
  providerCatalogSnapshot,
} from "../src/catalog.ts";

describe("provider catalog", () => {
  it("matches generated protocol PROVIDER_IDS", () => {
    expect([...PROVIDER_ORDER].sort()).toEqual([...PROVIDER_IDS].sort());
    expect(new Set(PROVIDER_ORDER).size).toBe(PROVIDER_ORDER.length);
    for (const id of PROVIDER_IDS) {
      expect(PROVIDER_CATALOG[id].id).toBe(id);
    }
  });

  it("lists configurable providers only when config is set", () => {
    expect(configurableProviderIds()).toEqual(["openrouter", "deepseek", "kimi", "litellm"]);
    expect(PROVIDER_CATALOG.openrouter.config?.kind).toBe("api_key");
    expect(PROVIDER_CATALOG.deepseek.config?.kind).toBe("api_key");
    expect(PROVIDER_CATALOG.kimi.config?.kind).toBe("api_key");
    expect(PROVIDER_CATALOG.litellm.config?.kind).toBe("api_key");
    expect(PROVIDER_CATALOG.codex.config).toBeNull();
  });

  it("auth messages never embed raw secrets", () => {
    for (const id of PROVIDER_ORDER) {
      const message = authRequiredMessage(id);
      expect(message).not.toMatch(/sk-or-v1-|Bearer |eyJ/);
      expect(message.length).toBeGreaterThan(10);
    }
  });

  it("snapshot is stable for Swift codegen", () => {
    const snapshot = providerCatalogSnapshot();
    expect(snapshot.map((e) => e.id)).toEqual(PROVIDER_ORDER);
  });
});
