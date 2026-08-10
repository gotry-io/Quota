import { describe, expect, it } from "vitest";
import { ApiKeyHttpCollector } from "../src/api-key/collector.ts";
import {
  mapOpenRouterCreditsResponse,
  mapOpenRouterKeyResponse,
  mapOpenRouterWindows,
} from "../src/providers/openrouter/map.ts";
import { openrouterSpec } from "../src/providers/openrouter/spec.ts";
import type { HttpRequest, HttpResponse } from "../src/runtime/http.ts";

describe("openrouter mapping", () => {
  it("maps credits and prefers key-limit remaining for the primary window", () => {
    const credits = mapOpenRouterCreditsResponse({
      data: { total_credits: 50, total_usage: 45 },
    });
    const key = mapOpenRouterKeyResponse({
      data: {
        limit: 20,
        limit_remaining: 15,
        usage: 5,
        usage_daily: 1,
        usage_weekly: 3,
        usage_monthly: 5,
        limit_reset: "monthly",
        rate_limit: { requests: 1000, interval: "1d" },
      },
    });
    expect(credits?.balance).toBe(5);
    const windows = mapOpenRouterWindows(credits!, key);
    expect(windows[0]).toMatchObject({
      id: "key_monthly",
      title: "API key monthly",
      used_percent: 25,
      remaining_value: 15,
      limit_value: 20,
      value_unit: "usd",
    });
    expect(windows[1]).toMatchObject({
      id: "credits",
      title: "Credits",
      used_percent: 0,
      remaining_value: 5,
      value_unit: "usd",
    });
    expect(windows[1]?.limit_value).toBeUndefined();
  });

  it("omits key window when no limit is configured and keeps credits", () => {
    const credits = mapOpenRouterCreditsResponse({
      data: { total_credits: 10, total_usage: 2 },
    });
    const key = mapOpenRouterKeyResponse({
      data: { limit: null, usage: 2 },
    });
    const windows = mapOpenRouterWindows(credits!, key);
    expect(windows).toHaveLength(1);
    expect(windows[0]?.id).toBe("credits");
    expect(windows[0]).toMatchObject({ used_percent: 0, remaining_value: 8, value_unit: "usd" });
    expect(windows[0]?.limit_value).toBeUndefined();
  });

  it("keeps key-limit when prepaid credits are zero", () => {
    const credits = mapOpenRouterCreditsResponse({
      data: { total_credits: 0, total_usage: 0 },
    });
    const key = mapOpenRouterKeyResponse({
      data: { limit: 25, limit_remaining: 10, usage: 15, limit_reset: "daily" },
    });
    const windows = mapOpenRouterWindows(credits, key);
    expect(windows).toHaveLength(1);
    expect(windows[0]?.id).toBe("key_daily");
    expect(windows[0]?.remaining_value).toBe(10);
  });
});

describe("openrouter collector", () => {
  it("collects credits and key quota from fixed HTTPS endpoints", async () => {
    const calls: string[] = [];
    const transport = async (request: HttpRequest): Promise<HttpResponse> => {
      calls.push(request.url);
      expect(request.headers?.Authorization).toBe("Bearer sk-or-v1-fixture");
      if (request.url.endsWith("/credits")) {
        return jsonResponse(200, { data: { total_credits: 100, total_usage: 40 } });
      }
      if (request.url.endsWith("/key")) {
        return jsonResponse(200, {
          data: { limit: 50, limit_remaining: 30, usage: 20, limit_reset: "daily" },
        });
      }
      return jsonResponse(404, {});
    };

    const collector = new ApiKeyHttpCollector(openrouterSpec, {
      environment: { OPENROUTER_API_KEY: "sk-or-v1-fixture" },
      configPath: "/tmp/quota-openrouter-missing-config.json",
      transport,
      clientVersion: "QuotaCLI/test",
    });
    const sessions = await collector.discover();
    expect(sessions).toHaveLength(1);
    expect(sessions[0]?.credential_source).toBe("env:OPENROUTER_API_KEY");
    const snapshot = await collector.collect(sessions[0]!);
    expect(snapshot.provider).toBe("openrouter");
    expect(snapshot.account.plan).toBe("Credits");
    expect(snapshot.windows[0]?.used_percent).toBe(40);
    expect(snapshot.windows[1]?.id).toBe("credits");
    expect(JSON.stringify(snapshot)).not.toContain("sk-or-v1-fixture");
    expect(calls).toEqual([
      "https://openrouter.ai/api/v1/credits",
      "https://openrouter.ai/api/v1/key",
    ]);
  });

  it("succeeds with credits alone when key endpoint fails", async () => {
    const transport = async (request: HttpRequest): Promise<HttpResponse> => {
      if (request.url.endsWith("/credits")) {
        return jsonResponse(200, { data: { total_credits: 10, total_usage: 1 } });
      }
      return jsonResponse(500, { error: "nope" });
    };
    const collector = new ApiKeyHttpCollector(openrouterSpec, {
      environment: { OPENROUTER_API_KEY: "sk-or-v1-fixture" },
      configPath: "/tmp/quota-openrouter-missing-config.json",
      transport,
    });
    const snapshot = await collector.collect({
      provider: "openrouter",
      session_id: "ambient",
      display_label: "OpenRouter",
      credential_source: "env:OPENROUTER_API_KEY",
    });
    expect(snapshot.windows).toHaveLength(1);
    expect(snapshot.windows[0]?.id).toBe("credits");
  });

  it("fetches independent credits and key meters concurrently", async () => {
    let active = 0;
    let maximumActive = 0;
    const transport = async (request: HttpRequest): Promise<HttpResponse> => {
      active += 1;
      maximumActive = Math.max(maximumActive, active);
      await Promise.resolve();
      active -= 1;
      return request.url.endsWith("/credits")
        ? jsonResponse(200, { data: { total_credits: 10, total_usage: 1 } })
        : jsonResponse(200, { data: { limit: 20, limit_remaining: 10, usage: 10 } });
    };
    const collector = new ApiKeyHttpCollector(openrouterSpec, {
      environment: { OPENROUTER_API_KEY: "sk-or-v1-fixture" },
      configPath: "/tmp/quota-openrouter-missing-config.json",
      transport,
    });

    await collector.collect({
      provider: "openrouter",
      session_id: "ambient",
      display_label: "OpenRouter",
      credential_source: "env:OPENROUTER_API_KEY",
    });
    expect(maximumActive).toBe(2);
  });

  it("succeeds with key-limit alone when credits are zero", async () => {
    const transport = async (request: HttpRequest): Promise<HttpResponse> => {
      if (request.url.endsWith("/credits")) {
        return jsonResponse(200, { data: { total_credits: 0, total_usage: 0 } });
      }
      if (request.url.endsWith("/key")) {
        return jsonResponse(200, {
          data: { limit: 20, limit_remaining: 12, usage: 8, limit_reset: "monthly" },
        });
      }
      return jsonResponse(404, {});
    };
    const collector = new ApiKeyHttpCollector(openrouterSpec, {
      environment: { OPENROUTER_API_KEY: "sk-or-v1-fixture" },
      configPath: "/tmp/quota-openrouter-missing-config.json",
      transport,
    });
    const snapshot = await collector.collect({
      provider: "openrouter",
      session_id: "ambient",
      display_label: "OpenRouter",
      credential_source: "env:OPENROUTER_API_KEY",
    });
    expect(snapshot.windows).toHaveLength(1);
    expect(snapshot.windows[0]).toMatchObject({
      id: "key_monthly",
      remaining_value: 12,
      limit_value: 20,
    });
  });

  it("succeeds with key-limit when credits endpoint is unavailable", async () => {
    const transport = async (request: HttpRequest): Promise<HttpResponse> => {
      if (request.url.endsWith("/credits")) {
        return jsonResponse(503, { error: "credits down" });
      }
      if (request.url.endsWith("/key")) {
        return jsonResponse(200, {
          data: { limit: 10, limit_remaining: 4, usage: 6, limit_reset: "daily" },
        });
      }
      return jsonResponse(404, {});
    };
    const collector = new ApiKeyHttpCollector(openrouterSpec, {
      environment: { OPENROUTER_API_KEY: "sk-or-v1-fixture" },
      configPath: "/tmp/quota-openrouter-missing-config.json",
      transport,
    });
    const snapshot = await collector.collect({
      provider: "openrouter",
      session_id: "ambient",
      display_label: "OpenRouter",
      credential_source: "env:OPENROUTER_API_KEY",
    });
    expect(snapshot.windows).toHaveLength(1);
    expect(snapshot.windows[0]?.id).toBe("key_daily");
  });

  it("preserves unavailable when both independent quota endpoints fail", async () => {
    const transport = async (): Promise<HttpResponse> =>
      jsonResponse(503, { error: "provider-owned detail should not escape" });
    const collector = new ApiKeyHttpCollector(openrouterSpec, {
      environment: { OPENROUTER_API_KEY: "sk-or-v1-fixture" },
      configPath: "/tmp/quota-openrouter-missing-config.json",
      transport,
    });
    const collection = collector.collect({
      provider: "openrouter",
      session_id: "ambient",
      display_label: "OpenRouter",
      credential_source: "env:OPENROUTER_API_KEY",
    });
    await expect(collection).rejects.toMatchObject({
      category: "unavailable",
    });
    await expect(collection).rejects.not.toThrow(/provider-owned detail/);
  });

  it("reports auth_required for 401 without echoing the key", async () => {
    const transport = async (): Promise<HttpResponse> =>
      jsonResponse(401, { error: "invalid sk-or-v1-super-secret" });
    const collector = new ApiKeyHttpCollector(openrouterSpec, {
      environment: { OPENROUTER_API_KEY: "sk-or-v1-super-secret" },
      configPath: "/tmp/quota-openrouter-missing-config.json",
      transport,
    });
    await expect(
      collector.collect({
        provider: "openrouter",
        session_id: "ambient",
        display_label: "OpenRouter",
        credential_source: "env:OPENROUTER_API_KEY",
      }),
    ).rejects.toMatchObject({ category: "auth_required" });
  });
});

function jsonResponse(status: number, body: unknown): HttpResponse {
  return {
    status,
    headers: new Headers({ "content-type": "application/json" }),
    bodyText: JSON.stringify(body),
  };
}
