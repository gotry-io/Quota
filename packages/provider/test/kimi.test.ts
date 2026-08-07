import { describe, expect, it } from "vitest";
import { ApiKeyHttpCollector } from "../src/api-key/collector.ts";
import { mapKimiUsagesResponse, mapKimiWindows } from "../src/providers/kimi/map.ts";
import { kimiSpec } from "../src/providers/kimi/spec.ts";
import type { HttpRequest, HttpResponse } from "../src/runtime/http.ts";

describe("kimi mapping", () => {
  it("maps weekly usage and 5-hour rate limit windows", () => {
    const data = mapKimiUsagesResponse({
      usage: {
        limit: "2048",
        used: "214",
        remaining: "1834",
        resetTime: "2026-01-09T15:23:13.716839300Z",
      },
      limits: [
        {
          window: { duration: 300, timeUnit: "TIME_UNIT_MINUTE" },
          detail: {
            limit: "200",
            used: "139",
            remaining: "61",
            resetTime: "2026-01-06T13:33:02.717479433Z",
          },
        },
      ],
    });
    const windows = mapKimiWindows(data!);
    expect(windows[0]).toMatchObject({
      id: "weekly",
      title: "Weekly",
      used_percent: expect.closeTo(10.45, 1),
      remaining_value: 1834,
      limit_value: 2048,
      value_unit: "count",
    });
    expect(windows[1]).toMatchObject({
      id: "five_hour",
      title: "5 hour",
      used_percent: expect.closeTo(69.5, 1),
      remaining_value: 61,
      limit_value: 200,
      value_unit: "count",
    });
  });
});

describe("kimi collector", () => {
  it("collects usages via Code API key", async () => {
    const transport = async (request: HttpRequest): Promise<HttpResponse> => {
      expect(request.url).toBe("https://api.kimi.com/coding/v1/usages");
      expect(request.headers?.Authorization).toBe("Bearer kimi-fixture-key");
      return jsonResponse(200, {
        usage: { limit: "100", used: "25", remaining: "75" },
        limits: [
          {
            window: { duration: 300, timeUnit: "TIME_UNIT_MINUTE" },
            detail: { limit: "50", used: "10", remaining: "40" },
          },
        ],
      });
    };
    const collector = new ApiKeyHttpCollector(kimiSpec, {
      environment: { KIMI_CODE_API_KEY: "kimi-fixture-key" },
      configPath: "/tmp/quota-kimi-missing-config.json",
      transport,
    });
    const snapshot = await collector.collect({
      provider: "kimi",
      session_id: "ambient",
      display_label: "Kimi",
      credential_source: "env:KIMI_CODE_API_KEY",
    });
    expect(snapshot.provider).toBe("kimi");
    expect(snapshot.windows).toHaveLength(2);
    expect(JSON.stringify(snapshot)).not.toContain("kimi-fixture-key");
  });
});

function jsonResponse(status: number, body: unknown): HttpResponse {
  return {
    status,
    headers: new Headers({ "content-type": "application/json" }),
    bodyText: JSON.stringify(body),
  };
}
