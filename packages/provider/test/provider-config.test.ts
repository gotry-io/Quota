import { mkdtemp, readFile, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { ProviderConfigStore, ProviderConfigStoreError } from "../src/config/store.ts";
import { resolveOpenRouterCredentials } from "../src/providers/openrouter/credentials.ts";

describe("ProviderConfigStore", () => {
  it("saves openrouter keys owner-only and prefers them over env", async () => {
    const root = await mkdtemp(join(tmpdir(), "quota-provider-config-"));
    const path = join(root, "providers.json");
    const store = new ProviderConfigStore({ path });

    await store.set("openrouter", { api_key: "sk-or-v1-config-key" });
    const metadata = await stat(path);
    expect(metadata.mode & 0o077).toBe(0);

    const raw = await readFile(path, "utf8");
    expect(raw).toContain("sk-or-v1-config-key");
    expect(JSON.parse(raw).schema_version).toBe(1);

    const resolved = await resolveOpenRouterCredentials({
      path,
      environment: { OPENROUTER_API_KEY: "sk-or-v1-env-key" },
    });
    expect(resolved?.apiKey).toBe("sk-or-v1-config-key");
    expect(resolved?.source).toBe("config:openrouter");
    expect(JSON.stringify(resolved)).not.toContain("sk-or-v1-env-key");
  });

  it("falls back to env when config is empty", async () => {
    const root = await mkdtemp(join(tmpdir(), "quota-provider-config-"));
    const path = join(root, "providers.json");
    const resolved = await resolveOpenRouterCredentials({
      path,
      environment: { OPENROUTER_API_KEY: "sk-or-v1-env-only" },
    });
    expect(resolved?.apiKey).toBe("sk-or-v1-env-only");
    expect(resolved?.source).toBe("env:OPENROUTER_API_KEY");
  });

  it("unsets and lists configured providers", async () => {
    const root = await mkdtemp(join(tmpdir(), "quota-provider-config-"));
    const path = join(root, "providers.json");
    const store = new ProviderConfigStore({ path });
    await store.set("openrouter", {
      api_key: "sk-or-v1-x",
      base_url: "https://openrouter.ai/api/v1",
    });
    expect(await store.listConfigured()).toEqual(["openrouter"]);
    expect(await store.unset("openrouter")).toBe(true);
    expect(await store.listConfigured()).toEqual([]);
    expect(await store.unset("openrouter")).toBe(false);
  });

  it("rejects empty keys", async () => {
    const root = await mkdtemp(join(tmpdir(), "quota-provider-config-"));
    const store = new ProviderConfigStore({ path: join(root, "providers.json") });
    await expect(store.set("openrouter", { api_key: "  " })).rejects.toBeInstanceOf(
      ProviderConfigStoreError,
    );
  });
});
