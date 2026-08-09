import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { ApiKeyHttpCollector } from "../src/api-key/collector.ts";
import {
  mapLiteLLMKeyInfo,
  mapLiteLLMUserInfo,
  mapLiteLLMWindows,
} from "../src/providers/litellm/map.ts";
import { litellmSpec } from "../src/providers/litellm/spec.ts";
import type { HttpRequest, HttpResponse } from "../src/runtime/http.ts";

describe("litellm mapping", () => {
  it("maps personal budget windows from spend and max_budget", () => {
    const personal = mapLiteLLMUserInfo({
      user_info: { spend: 25, max_budget: 100 },
    });
    expect(personal).toMatchObject({ spendUsd: 25, budgetUsd: 100 });
    const windows = mapLiteLLMWindows({ personal: personal! });
    expect(windows[0]).toMatchObject({
      id: "personal",
      used_percent: 25,
      remaining_value: 75,
      limit_value: 100,
      value_unit: "usd",
    });
  });

  it("reads key info user_id", () => {
    expect(mapLiteLLMKeyInfo({ info: { user_id: "u1", team_id: "t1" } })).toEqual({
      userId: "u1",
      teamId: "t1",
    });
  });

  it("does not turn spend without a budget into fabricated quota", () => {
    const windows = mapLiteLLMWindows({
      personal: { spendUsd: 12.5, label: "Personal" },
    });
    expect(windows).toEqual([]);
  });
});

describe("litellm collector", () => {
  it("requires base URL and fetches key + user info", async () => {
    const calls: string[] = [];
    const transport = async (request: HttpRequest): Promise<HttpResponse> => {
      calls.push(request.url);
      expect(request.headers?.Authorization).toBe("Bearer sk-litellm-fixture");
      if (request.url.endsWith("/key/info")) {
        return jsonResponse(200, { info: { user_id: "user-1", team_id: "team-1" } });
      }
      if (request.url.includes("/user/info")) {
        return jsonResponse(200, { user_info: { spend: 10, max_budget: 50 } });
      }
      if (request.url.includes("/team/info")) {
        return jsonResponse(200, {
          team_info: { team_id: "team-1", spend: 5, max_budget: 200, team_alias: "eng" },
        });
      }
      return jsonResponse(404, {});
    };

    const collector = new ApiKeyHttpCollector(litellmSpec, {
      environment: {
        LITELLM_API_KEY: "sk-litellm-fixture",
        LITELLM_BASE_URL: "https://litellm.example.com/v1",
      },
      configPath: "/tmp/quota-litellm-missing-config.json",
      transport,
    });
    const sessions = await collector.discover();
    expect(sessions).toHaveLength(1);
    const snapshot = await collector.collect(sessions[0]!);
    expect(snapshot.provider).toBe("litellm");
    expect(snapshot.windows.map((w) => w.id)).toEqual(["personal", "team"]);
    expect(calls[0]).toBe("https://litellm.example.com/key/info");
    expect(JSON.stringify(snapshot)).not.toContain("sk-litellm-fixture");
  });

  it("is unavailable without base URL", async () => {
    const collector = new ApiKeyHttpCollector(litellmSpec, {
      environment: { LITELLM_API_KEY: "sk-only" },
      configPath: "/tmp/quota-litellm-missing-config.json",
    });
    expect(await collector.discover()).toEqual([]);
  });

  it("treats an invalid stored base URL as unavailable", async () => {
    const root = await mkdtemp(join(tmpdir(), "quota-litellm-invalid-url-"));
    const configPath = join(root, "providers.json");
    await writeFile(
      configPath,
      `${JSON.stringify({
        schema_version: 1,
        providers: {
          litellm: { api_key: "sk-litellm-invalid-url", base_url: "ftp://invalid.example" },
        },
      })}\n`,
      { mode: 0o600 },
    );
    const collector = new ApiKeyHttpCollector(litellmSpec, { configPath, environment: {} });
    await expect(collector.discover()).resolves.toEqual([]);
  });

  it("fetches independent user and team budgets concurrently after key discovery", async () => {
    let active = 0;
    let maximumActive = 0;
    const transport = async (request: HttpRequest): Promise<HttpResponse> => {
      if (request.url.endsWith("/key/info")) {
        return jsonResponse(200, { info: { user_id: "user-1", team_id: "team-1" } });
      }
      active += 1;
      maximumActive = Math.max(maximumActive, active);
      await Promise.resolve();
      active -= 1;
      return request.url.includes("/user/info")
        ? jsonResponse(200, { user_info: { spend: 10, max_budget: 50 } })
        : jsonResponse(200, {
            team_info: { team_id: "team-1", spend: 5, max_budget: 200 },
          });
    };
    const collector = new ApiKeyHttpCollector(litellmSpec, {
      environment: {
        LITELLM_API_KEY: "sk-litellm-fixture",
        LITELLM_BASE_URL: "https://litellm.example.com",
      },
      configPath: "/tmp/quota-litellm-missing-config.json",
      transport,
    });

    await collector.collect({
      provider: "litellm",
      session_id: "ambient",
      display_label: "LiteLLM",
      credential_source: "env:LITELLM_API_KEY",
    });
    expect(maximumActive).toBe(2);
  });
});

function jsonResponse(status: number, body: unknown): HttpResponse {
  return {
    status,
    headers: new Headers({ "content-type": "application/json" }),
    bodyText: JSON.stringify(body),
  };
}
