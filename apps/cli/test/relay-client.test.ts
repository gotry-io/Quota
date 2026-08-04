import type { PairingCreateResponse, QuotaSnapshotEnvelope } from "@gotry-io/quota-protocol";
import { afterEach, describe, expect, it, vi } from "vitest";
import { RelayClient, RelayClientError, type RelayFetch } from "../src/relay/client.ts";

const discovery = {
  instance_id: "relay_test",
  mode: "self_hosted",
  version: "0.0.1",
  api_versions: [1],
  auth_methods: ["bearer"],
  capabilities: {
    realtime: false,
    persistent_snapshots: true,
    instant_device_revocation: true,
    history: false,
    multi_tenant: false,
  },
} as const;

const pairing: PairingCreateResponse = {
  device_code: "synthetic-device-code",
  user_code: "TEST-CODE",
  expires_at: "2026-08-03T10:10:00Z",
  poll_interval_seconds: 5,
};

afterEach(() => {
  vi.useRealTimers();
});

describe("RelayClient discovery and pairing", () => {
  it("discovers required capabilities and creates a protocol-validated pairing", async () => {
    const fetchMock = vi
      .fn<RelayFetch>()
      .mockResolvedValueOnce(jsonResponse(discovery))
      .mockResolvedValueOnce(jsonResponse(pairing, 201));
    const client = new RelayClient("https://relay.example.com/", { fetch: fetchMock });

    await expect(client.discover()).resolves.toEqual(discovery);
    await expect(client.createPairing("Kitchen Mac")).resolves.toEqual(pairing);

    expect(fetchMock.mock.calls[0]?.[0]).toBe(
      "https://relay.example.com/.well-known/quotabar-relay",
    );
    expect(fetchMock.mock.calls[1]?.[0]).toBe("https://relay.example.com/api/v1/pairings");
    expect(fetchMock.mock.calls[1]?.[1]).toMatchObject({
      method: "POST",
      redirect: "error",
      body: JSON.stringify({ device_display_name: "Kitchen Mac" }),
    });
  });

  it.each([
    [{ api_versions: [] }, "invalid_response"],
    [{ auth_methods: [] }, "unsupported_relay"],
    [
      { capabilities: { ...discovery.capabilities, persistent_snapshots: false } },
      "unsupported_relay",
    ],
    [
      { capabilities: { ...discovery.capabilities, instant_device_revocation: false } },
      "unsupported_relay",
    ],
  ])("rejects missing required discovery capability %#", async (override, code) => {
    const client = clientWithResponses(jsonResponse({ ...discovery, ...override }));
    await expectErrorCode(client.discover(), code);
  });

  it("strictly rejects unknown discovery and pairing fields", async () => {
    const discoveryClient = clientWithResponses(jsonResponse({ ...discovery, unexpected: true }));
    await expectErrorCode(discoveryClient.discover(), "invalid_response");

    const pairingClient = clientWithResponses(jsonResponse({ ...pairing, unexpected: true }, 201));
    await expectErrorCode(pairingClient.createPairing("Kitchen Mac"), "invalid_response");
  });

  it("sets redirect error and returns a fixed error without transport details", async () => {
    const fetchMock = vi.fn<RelayFetch>(async (_input, init) => {
      expect(init?.redirect).toBe("error");
      throw new TypeError("redirect failed for synthetic-device-code?token=secret-token");
    });
    const client = new RelayClient("https://relay.example.com", { fetch: fetchMock });

    const error = await captureError(client.discover());
    expect(error).toMatchObject({ code: "unavailable", message: "The Relay request failed." });
    expect(error.message).not.toMatch(/synthetic-device-code|secret-token/);
  });

  it("enforces the request timeout", async () => {
    vi.useFakeTimers();
    const fetchMock = vi.fn<RelayFetch>(
      (_input, init) =>
        new Promise((_resolve, reject) => {
          init?.signal?.addEventListener(
            "abort",
            () => reject(new DOMException("contains-secret", "AbortError")),
            { once: true },
          );
        }),
    );
    const client = new RelayClient("https://relay.example.com", {
      fetch: fetchMock,
    });

    const pendingAssertion = expectErrorCode(client.discover(), "timeout");
    await vi.advanceTimersByTimeAsync(20_000);
    await pendingAssertion;
  });

  it("rejects a response body over 1 MiB without including it in the error", async () => {
    const secret = "secret-device-token";
    const oversizedBody = `${"x".repeat(1024 * 1024 + 1)}${secret}`;
    const client = new RelayClient("https://relay.example.com", {
      fetch: vi.fn<RelayFetch>().mockResolvedValue(new Response(oversizedBody)),
    });

    const error = await captureError(client.discover());
    expect(error.code).toBe("invalid_response");
    expect(error.message).not.toContain(secret);
  });

  it("does not surface Relay error bodies", async () => {
    const client = clientWithResponses(
      jsonResponse(
        {
          error: {
            code: "pairing_denied",
            message: "Bearer secret-device-token synthetic-device-code",
          },
        },
        409,
      ),
    );

    const error = await captureError(client.createPairing("Kitchen Mac"));
    expect(error).toMatchObject({ code: "pairing_denied" });
    expect(error.message).not.toMatch(/secret-device-token|synthetic-device-code|Bearer/);
  });
});

describe("RelayClient pairing polling", () => {
  it("polls pending sessions at the server interval and returns issued credentials", async () => {
    let now = Date.parse("2026-08-03T10:00:00Z");
    const sleeps: number[] = [];
    const fetchMock = vi
      .fn<RelayFetch>()
      .mockResolvedValueOnce(jsonResponse({ status: "pending", poll_interval_seconds: 7 }, 202))
      .mockResolvedValueOnce(
        jsonResponse({ device_id: "device_test", device_token: "issued-secret-token" }),
      );
    const client = new RelayClient("https://relay.example.com", {
      fetch: fetchMock,
      now: () => new Date(now),
      sleep: async (milliseconds) => {
        sleeps.push(milliseconds);
        now += milliseconds;
      },
    });

    await expect(client.pollPairing(pairing)).resolves.toEqual({
      device_id: "device_test",
      device_token: "issued-secret-token",
    });
    expect(sleeps).toEqual([5_000, 7_000]);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(fetchMock.mock.calls[0]?.[1]?.body).toBe(
      JSON.stringify({ device_code: pairing.device_code }),
    );
  });

  it.each([
    [409, "pairing_denied"],
    [410, "pairing_expired"],
    [409, "pairing_consumed"],
    [404, "not_found"],
  ] as const)("handles terminal %s %s polling errors", async (status, code) => {
    const client = clientWithResponses(
      jsonResponse({ error: { code, message: "synthetic server message" } }, status),
      () => new Date("2026-08-03T10:00:00Z"),
    );
    await expectErrorCode(client.pollPairing(pairing), code);
  });

  it("honors Retry-After before polling again", async () => {
    let now = Date.parse("2026-08-03T10:00:00Z");
    const sleeps: number[] = [];
    const fetchMock = vi
      .fn<RelayFetch>()
      .mockResolvedValueOnce(
        jsonResponse({ error: { code: "rate_limited", message: "secret-token" } }, 429, {
          "Retry-After": "11",
        }),
      )
      .mockResolvedValueOnce(
        jsonResponse({ device_id: "device_test", device_token: "issued-secret-token" }),
      );
    const client = new RelayClient("https://relay.example.com", {
      fetch: fetchMock,
      now: () => new Date(now),
      sleep: async (milliseconds) => {
        sleeps.push(milliseconds);
        now += milliseconds;
      },
    });

    await expect(client.pollPairing(pairing)).resolves.toMatchObject({ device_id: "device_test" });
    expect(sleeps).toEqual([5_000, 11_000]);
  });

  it("never sends a poll at or beyond expires_at", async () => {
    let now = Date.parse("2026-08-03T10:09:58Z");
    const sleeps: number[] = [];
    const fetchMock = vi
      .fn<RelayFetch>()
      .mockResolvedValue(jsonResponse({ status: "pending", poll_interval_seconds: 30 }, 202));
    const client = new RelayClient("https://relay.example.com", {
      fetch: fetchMock,
      now: () => new Date(now),
      sleep: async (milliseconds) => {
        sleeps.push(milliseconds);
        now += milliseconds;
      },
    });

    await expectErrorCode(client.pollPairing(pairing), "pairing_expired");
    expect(sleeps).toEqual([2_000]);
    expect(fetchMock).not.toHaveBeenCalled();

    now = Date.parse(pairing.expires_at);
    fetchMock.mockClear();
    await expectErrorCode(client.pollPairing(pairing), "pairing_expired");
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("rejects malformed pending and issued responses", async () => {
    const pendingClient = clientWithResponses(
      jsonResponse({ status: "pending", poll_interval_seconds: 5, extra: true }, 202),
      () => new Date("2026-08-03T10:00:00Z"),
    );
    await expectErrorCode(pendingClient.pollPairing(pairing), "invalid_response");

    const issuedClient = clientWithResponses(
      jsonResponse({ device_id: "device_test", device_token: "token", extra: true }),
      () => new Date("2026-08-03T10:00:00Z"),
    );
    await expectErrorCode(issuedClient.pollPairing(pairing), "invalid_response");
  });
});

describe("RelayClient snapshot upload", () => {
  it("discovers without authentication and uploads the exact envelope with device Bearer auth", async () => {
    const fetchMock = vi
      .fn<RelayFetch>()
      .mockResolvedValueOnce(jsonResponse(discovery))
      .mockResolvedValueOnce(new Response(null, { status: 204 }));
    const client = new RelayClient("https://relay.example.com", { fetch: fetchMock });

    await client.discover();
    await client.uploadSnapshot("synthetic-device-token", snapshotEnvelope);

    const discoveryHeaders = new Headers(fetchMock.mock.calls[0]?.[1]?.headers);
    expect(discoveryHeaders.has("Authorization")).toBe(false);
    expect(fetchMock.mock.calls[1]?.[0]).toBe("https://relay.example.com/api/v1/snapshots");
    expect(fetchMock.mock.calls[1]?.[1]).toMatchObject({
      method: "POST",
      redirect: "error",
      body: JSON.stringify(snapshotEnvelope),
    });
    const uploadHeaders = new Headers(fetchMock.mock.calls[1]?.[1]?.headers);
    expect(uploadHeaders.get("Authorization")).toBe("Bearer synthetic-device-token");
    expect(uploadHeaders.get("Content-Type")).toBe("application/json");
  });

  it.each([
    [401, "unauthorized"],
    [200, "internal_error"],
  ] as const)("rejects non-204 snapshot status %s", async (status, code) => {
    const client = new RelayClient("https://relay.example.com", {
      fetch: vi.fn<RelayFetch>().mockResolvedValue(
        jsonResponse(
          {
            error: {
              code,
              message: "Authorization Bearer synthetic-device-token raw-body-secret",
            },
          },
          status,
        ),
      ),
    });

    const error = await captureError(
      client.uploadSnapshot("synthetic-device-token", snapshotEnvelope),
    );
    expect(error.code).toBe(code);
    expect(error.message).not.toMatch(/synthetic-device-token|raw-body-secret|Authorization/);
  });

  it("rejects an invalid envelope before sending the device credential", async () => {
    const fetchMock = vi.fn<RelayFetch>();
    const client = new RelayClient("https://relay.example.com", { fetch: fetchMock });

    await expectErrorCode(
      client.uploadSnapshot("synthetic-device-token", {
        ...snapshotEnvelope,
        sequence: -1,
      }),
      "invalid_request",
    );
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe("RelayClient device self-revocation", () => {
  it("sends the device Bearer credential only to the fixed self endpoint", async () => {
    const fetchMock = vi.fn<RelayFetch>().mockResolvedValue(new Response(null, { status: 204 }));
    const client = new RelayClient("https://relay.example.com", { fetch: fetchMock });

    await expect(client.revokeSelf("synthetic-device-token")).resolves.toBeUndefined();

    expect(fetchMock).toHaveBeenCalledOnce();
    expect(fetchMock.mock.calls[0]?.[0]).toBe("https://relay.example.com/api/v1/devices/self");
    expect(fetchMock.mock.calls[0]?.[1]).toMatchObject({
      method: "DELETE",
      redirect: "error",
    });
    expect(fetchMock.mock.calls[0]?.[1]?.body).toBeUndefined();
    const headers = new Headers(fetchMock.mock.calls[0]?.[1]?.headers);
    expect(headers.get("Authorization")).toBe("Bearer synthetic-device-token");
    expect(headers.has("Content-Type")).toBe(false);
  });

  it("does not treat an unauthorized credential as proof of revocation", async () => {
    const client = new RelayClient("https://relay.example.com", {
      fetch: vi.fn<RelayFetch>().mockResolvedValue(
        jsonResponse(
          {
            error: {
              code: "unauthorized",
              message: "Authorization Bearer synthetic-device-token raw-body-secret",
            },
          },
          401,
        ),
      ),
    });

    const error = await captureError(client.revokeSelf("synthetic-device-token"));
    expect(error).toMatchObject({
      code: "unauthorized",
      status: 401,
      message: "The Relay rejected the request.",
    });
    expect(error.message).not.toMatch(/synthetic-device-token|raw-body-secret|Authorization/);
  });

  it("keeps other Relay failures explicit and free of response details", async () => {
    const client = new RelayClient("https://relay.example.com", {
      fetch: vi.fn<RelayFetch>().mockResolvedValue(
        jsonResponse(
          {
            error: {
              code: "internal_error",
              message: "Authorization Bearer synthetic-device-token raw-body-secret",
            },
          },
          500,
        ),
      ),
    });

    const error = await captureError(client.revokeSelf("synthetic-device-token"));
    expect(error).toMatchObject({
      code: "internal_error",
      message: "The Relay rejected the request.",
    });
    expect(error.message).not.toMatch(/synthetic-device-token|raw-body-secret|Authorization/);
  });

  it("rejects an invalid device credential before the request", async () => {
    const fetchMock = vi.fn<RelayFetch>();
    const client = new RelayClient("https://relay.example.com", { fetch: fetchMock });

    await expectErrorCode(client.revokeSelf(" surrounded "), "invalid_request");
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

const snapshotEnvelope: QuotaSnapshotEnvelope = {
  schema_version: 1,
  device_id: "device_test",
  sequence: 0,
  captured_at: "2026-08-03T10:00:00Z",
  snapshots: [
    {
      provider: "codex",
      account: { fingerprint: "codex-test", fingerprint_scope: "global" },
      windows: [],
      source: "codex_source",
      status: "available",
      observed_at: "2026-08-03T10:00:00Z",
    },
  ],
};

function clientWithResponses(response: Response, now?: () => Date): RelayClient {
  return new RelayClient("https://relay.example.com", {
    fetch: vi.fn<RelayFetch>().mockResolvedValue(response),
    ...(now ? { now } : {}),
    sleep: async () => undefined,
  });
}

function jsonResponse(body: unknown, status = 200, headers?: HeadersInit): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...headers },
  });
}

async function captureError(promise: Promise<unknown>): Promise<RelayClientError> {
  try {
    await promise;
  } catch (error) {
    expect(error).toBeInstanceOf(RelayClientError);
    return error as RelayClientError;
  }
  throw new Error("Expected RelayClientError.");
}

async function expectErrorCode(promise: Promise<unknown>, code: string): Promise<void> {
  const error = await captureError(promise);
  expect(error.code).toBe(code);
}
