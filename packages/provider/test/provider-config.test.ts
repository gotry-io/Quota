import { chmod, mkdir, mkdtemp, readFile, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { resolveApiKeyCredentials } from "../src/api-key/resolve.ts";
import { ProviderConfigStore, ProviderConfigStoreError } from "../src/config/store.ts";
import { openrouterSpec } from "../src/providers/openrouter/spec.ts";

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

    const resolved = await resolveApiKeyCredentials(openrouterSpec, {
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
    const resolved = await resolveApiKeyCredentials(openrouterSpec, {
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

  it("rejects fixed-provider base URLs and does not fall back after a stale one", async () => {
    const root = await mkdtemp(join(tmpdir(), "quota-provider-config-"));
    const path = join(root, "providers.json");
    const store = new ProviderConfigStore({ path });

    await expect(
      store.set("openrouter", {
        api_key: "sk-or-v1-fixed-endpoint",
        base_url: "https://untrusted.example/api/v1",
      }),
    ).rejects.toThrow("does not support custom base URLs");

    await writeFile(
      path,
      `${JSON.stringify({
        schema_version: 1,
        providers: {
          openrouter: {
            api_key: "sk-or-v1-stale-url",
            base_url: "https://untrusted.example/api/v1",
          },
        },
      })}\n`,
    );
    await chmod(path, 0o600);
    await expect(
      resolveApiKeyCredentials(openrouterSpec, {
        path,
        environment: { OPENROUTER_API_KEY: "sk-or-v1-env-fallback" },
      }),
    ).resolves.toBeUndefined();
  });

  it("serializes concurrent read-modify-write updates from separate stores", async () => {
    const root = await mkdtemp(join(tmpdir(), "quota-provider-config-"));
    const path = join(root, "providers.json");
    const openrouter = new ProviderConfigStore({ path });
    const deepseek = new ProviderConfigStore({ path });

    await Promise.all([
      openrouter.set("openrouter", { api_key: "sk-or-v1-concurrent" }),
      deepseek.set("deepseek", { api_key: "sk-deepseek-concurrent" }),
    ]);

    const config = await openrouter.load();
    expect(config.providers.openrouter?.api_key).toBe("sk-or-v1-concurrent");
    expect(config.providers.deepseek?.api_key).toBe("sk-deepseek-concurrent");
  });

  it("recovers a write lock whose owner process no longer exists", async () => {
    const root = await mkdtemp(join(tmpdir(), "quota-provider-config-"));
    const path = join(root, "providers.json");
    const lockPath = `${path}.lock`;
    await mkdir(lockPath, { mode: 0o700 });
    await writeFile(join(lockPath, "owner"), "2147483647\n", { mode: 0o600 });

    const store = new ProviderConfigStore({ path });
    await store.set("openrouter", { api_key: "sk-or-v1-after-stale-lock" });
    await expect(store.get("openrouter")).resolves.toMatchObject({
      api_key: "sk-or-v1-after-stale-lock",
    });
  });
});
