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
      used_percent: 90,
      remaining_value: 5,
      limit_value: 50,
      value_unit: "usd",
    });
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
    expect(windows[0]?.used_percent).toBe(20);
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
