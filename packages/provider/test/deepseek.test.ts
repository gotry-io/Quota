import { describe, expect, it } from "vitest";
import { ApiKeyHttpCollector } from "../src/api-key/collector.ts";
import { mapDeepSeekBalanceResponse, mapDeepSeekWindows } from "../src/providers/deepseek/map.ts";
import { deepseekSpec } from "../src/providers/deepseek/spec.ts";
import type { HttpRequest, HttpResponse } from "../src/runtime/http.ts";

/** Real-world shape: USD empty, CNY has remaining. */
const USER_FIXTURE = {
  is_available: true,
  balance_infos: [
    {
      currency: "CNY",
      total_balance: "3.96",
      granted_balance: "0.00",
      topped_up_balance: "3.96",
    },
    {
      currency: "USD",
      total_balance: "0.00",
      granted_balance: "0.00",
      topped_up_balance: "0.00",
    },
  ],
};

describe("deepseek mapping", () => {
  it("prefers positive balances so zero USD does not hide CNY", () => {
    const balances = mapDeepSeekBalanceResponse(USER_FIXTURE);
    expect(balances).toHaveLength(2);
    const windows = mapDeepSeekWindows(balances!);
    expect(windows).toHaveLength(1);
    expect(windows[0]).toMatchObject({
      id: "balance_cny",
      title: "Balance (CNY)",
      remaining_value: 3.96,
      used_percent: 0,
    });
    expect(windows[0]?.value_unit).toBeUndefined();
    expect(windows[0]?.limit_value).toBeUndefined();
  });

  it("shows positive USD and positive CNY as separate windows", () => {
    const balances = mapDeepSeekBalanceResponse({
      is_available: true,
      balance_infos: [
        {
          currency: "CNY",
          total_balance: "10.00",
          granted_balance: "0",
          topped_up_balance: "10",
        },
        {
          currency: "USD",
          total_balance: "42.5",
          granted_balance: "2.5",
          topped_up_balance: "40",
        },
      ],
    });
    const windows = mapDeepSeekWindows(balances!);
    expect(windows.map((w) => w.id)).toEqual(["balance", "balance_cny"]);
    expect(windows[0]).toMatchObject({
      title: "Balance (USD)",
      remaining_value: 42.5,
      value_unit: "usd",
    });
    expect(windows[1]).toMatchObject({
      title: "Balance (CNY)",
      remaining_value: 10,
    });
  });

  it("keeps a zero row when every currency is empty", () => {
    const balances = mapDeepSeekBalanceResponse({
      is_available: true,
      balance_infos: [
        { currency: "CNY", total_balance: 0 },
        { currency: "USD", total_balance: 0 },
      ],
    });
    expect(mapDeepSeekWindows(balances!)[0]).toMatchObject({
      id: "balance",
      title: "Balance (USD)",
      remaining_value: 0,
      value_unit: "usd",
    });
  });
});

describe("deepseek collector", () => {
  it("collects balance from the fixed HTTPS endpoint", async () => {
    const calls: string[] = [];
    const transport = async (request: HttpRequest): Promise<HttpResponse> => {
      calls.push(request.url);
      expect(request.headers?.Authorization).toBe("Bearer sk-deepseek-fixture");
      if (request.url.endsWith("/user/balance")) {
        return jsonResponse(200, USER_FIXTURE);
      }
      return jsonResponse(404, {});
    };

    const collector = new ApiKeyHttpCollector(deepseekSpec, {
      environment: { DEEPSEEK_API_KEY: "sk-deepseek-fixture" },
      configPath: "/tmp/quota-deepseek-missing-config.json",
      transport,
      clientVersion: "QuotaCLI/test",
    });
    const sessions = await collector.discover();
    expect(sessions).toHaveLength(1);
    const snapshot = await collector.collect(sessions[0]!);
    expect(snapshot.provider).toBe("deepseek");
    expect(snapshot.windows).toHaveLength(1);
    expect(snapshot.windows[0]).toMatchObject({
      id: "balance_cny",
      remaining_value: 3.96,
    });
    expect(JSON.stringify(snapshot)).not.toContain("sk-deepseek-fixture");
    expect(calls).toEqual(["https://api.deepseek.com/user/balance"]);
  });

  it("accepts DEEPSEEK_KEY env fallback", async () => {
    const transport = async (): Promise<HttpResponse> =>
      jsonResponse(200, {
        is_available: true,
        balance_infos: [{ currency: "USD", total_balance: "1" }],
      });
    const collector = new ApiKeyHttpCollector(deepseekSpec, {
      environment: { DEEPSEEK_KEY: "sk-alt-fixture" },
      configPath: "/tmp/quota-deepseek-missing-config.json",
      transport,
    });
    const sessions = await collector.discover();
    expect(sessions[0]?.credential_source).toBe("env:DEEPSEEK_KEY");
  });

  it("reports auth_required for 401 without echoing the key", async () => {
    const transport = async (): Promise<HttpResponse> =>
      jsonResponse(401, { error: "invalid sk-deepseek-super-secret" });
    const collector = new ApiKeyHttpCollector(deepseekSpec, {
      environment: { DEEPSEEK_API_KEY: "sk-deepseek-super-secret" },
      configPath: "/tmp/quota-deepseek-missing-config.json",
      transport,
    });
    await expect(
      collector.collect({
        provider: "deepseek",
        session_id: "ambient",
        display_label: "DeepSeek",
        credential_source: "env:DEEPSEEK_API_KEY",
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
