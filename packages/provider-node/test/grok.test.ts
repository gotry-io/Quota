import { describe, expect, it } from "vitest";
import {
  GROK_BILLING_URL,
  GROK_LEGACY_SESSION_SCOPE,
  GROK_OIDC_SCOPE_PREFIX,
  GROK_SOURCE_API,
  parseGrokCredentials,
} from "../src/index.ts";
import { GrokCollector } from "../src/providers/grok/collector.ts";
import { mapGrokBillingResponse } from "../src/providers/grok/map.ts";
import type { HttpRequest, HttpResponse } from "../src/runtime/http.ts";

const NOW = new Date("2026-08-02T12:00:00.000Z");

describe("grok credentials", () => {
  it("prefers OIDC scope entries with a non-empty key", () => {
    const credentials = parseGrokCredentials(
      {
        [`${GROK_OIDC_SCOPE_PREFIX}client`]: {
          key: "oidc-key",
          user_id: "user_1",
          email: "grok@example.com",
          first_name: "Grok",
          last_name: "User",
        },
        [GROK_LEGACY_SESSION_SCOPE]: {
          key: "legacy-key",
          user_id: "legacy_user",
        },
      },
      "/tmp/grok/auth.json",
    );
    expect(credentials?.userId).toBe("user_1");
    expect(credentials?.accessToken).toBe("oidc-key");
    expect(credentials?.scope.startsWith(GROK_OIDC_SCOPE_PREFIX)).toBe(true);
  });

  it("falls back to legacy sign-in when OIDC key is empty", () => {
    const credentials = parseGrokCredentials(
      {
        [`${GROK_OIDC_SCOPE_PREFIX}client`]: {
          key: "",
          user_id: "broken",
        },
        [GROK_LEGACY_SESSION_SCOPE]: {
          key: "legacy-key",
          user_id: "legacy_user",
        },
      },
      "/tmp/grok/auth.json",
    );
    expect(credentials?.userId).toBe("legacy_user");
  });
});

describe("grok billing mapping", () => {
  it("maps the current credits response and weekly period", () => {
    const mapped = mapGrokBillingResponse({
      config: {
        creditUsagePercent: 8,
        currentPeriod: {
          type: "USAGE_PERIOD_TYPE_WEEKLY",
          start: "2026-07-30T07:33:06Z",
          end: "2026-08-06T07:33:06Z",
        },
      },
    });
    expect(mapped.usable).toBe(true);
    expect(mapped.window).toMatchObject({
      id: "billing_cycle",
      title: "Weekly",
      used_percent: 8,
      duration_seconds: 7 * 24 * 60 * 60,
      resets_at: "2026-08-06T07:33:06Z",
    });
  });

  it("maps the deprecated non-unified account fields documented by Grok Build", () => {
    const mapped = mapGrokBillingResponse({
      config: {
        monthlyLimit: { val: 2000 },
        used: { val: 500 },
        billingPeriodStart: "2026-08-01T00:00:00Z",
        billingPeriodEnd: "2026-09-01T00:00:00Z",
      },
    });
    expect(mapped.usable).toBe(true);
    expect(mapped.window?.id).toBe("billing_cycle");
    expect(mapped.window?.used_percent).toBe(25);
    expect(mapped.window?.duration_seconds).toBe(31 * 24 * 60 * 60);
    expect(mapped.window?.resets_at).toBe("2026-09-01T00:00:00Z");
  });
});

describe("grok collector", () => {
  it("collects through the fixed official billing API and redacts credentials", async () => {
    let request: HttpRequest | undefined;
    const collector = new GrokCollector({
      clientVersion: "9.8.7",
      homeDirectory: "/home/quota",
      readJson: syntheticAuth,
      transport: async (input) => {
        request = input;
        return jsonResponse(200, {
          config: {
            creditUsagePercent: 8,
            currentPeriod: {
              type: "USAGE_PERIOD_TYPE_WEEKLY",
              start: "2026-07-30T07:33:06Z",
              end: "2026-08-06T07:33:06Z",
            },
          },
        });
      },
    });
    const snapshot = await collector.collect(grokSession(), { now: NOW });

    expect(snapshot.source).toBe(GROK_SOURCE_API);
    expect(snapshot.windows[0]?.used_percent).toBe(8);
    expect(request?.url).toBe(GROK_BILLING_URL);
    expect(request?.headers).toMatchObject({
      Authorization: "Bearer synthetic-token",
      "User-Agent": "QuotaCLI/9.8.7",
      "X-XAI-Token-Auth": "xai-grok-cli",
      "x-userid": "user_1",
    });
    expect(JSON.stringify(snapshot)).not.toContain("synthetic-token");
    expect(JSON.stringify(snapshot)).not.toContain("grok@example.com");
    expect(JSON.stringify(snapshot)).not.toContain("user_1");
  });

  it("classifies an unauthorized API response without exposing its body", async () => {
    const collector = new GrokCollector({
      homeDirectory: "/home/quota",
      readJson: syntheticAuth,
      transport: async () => jsonResponse(401, { error: "Bearer synthetic-token" }),
    });
    const collection = collector.collect(grokSession(), { now: NOW });
    await expect(collection).rejects.toMatchObject({
      category: "auth_required",
      source: GROK_SOURCE_API,
    });
    await expect(collection).rejects.not.toThrow(/synthetic-token/);
  });

  it("rejects malformed billing payloads", async () => {
    const collector = new GrokCollector({
      homeDirectory: "/home/quota",
      readJson: syntheticAuth,
      transport: async () => jsonResponse(200, { not: "billing" }),
    });
    await expect(
      collector.collect(
        {
          provider: "grok",
          session_id: "ambient",
          display_label: "Grok",
          credential_source: "/tmp/auth.json",
        },
        { now: NOW },
      ),
    ).rejects.toMatchObject({ category: "error", source: GROK_SOURCE_API });
  });
});

function syntheticAuth(): Promise<unknown> {
  return Promise.resolve({
    [`${GROK_OIDC_SCOPE_PREFIX}client`]: {
      key: "synthetic-token",
      user_id: "user_1",
      email: "grok@example.com",
    },
  });
}

function grokSession() {
  return {
    provider: "grok" as const,
    session_id: "ambient",
    display_label: "Grok",
    credential_source: "/tmp/auth.json",
  };
}

function jsonResponse(status: number, value: unknown): HttpResponse {
  return {
    status,
    headers: new Headers({ "content-type": "application/json" }),
    bodyText: JSON.stringify(value),
  };
}
