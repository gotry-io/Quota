import type {
  PairingCreateResponse,
  PairingTokenIssuedResponse,
  RelayInfo,
} from "@gotry-io/quota-protocol";
import { describe, expect, it, vi } from "vitest";
import { RelayClient, RelayClientError, type RelayFetch } from "../src/edge/client.ts";
import {
  type EdgeCommandDependencies,
  type EdgeCommandOutput,
  type EdgeCredentialStoreContract,
  type EdgeRelayClient,
  runEdgeCommand,
} from "../src/edge/commands.ts";
import type { EdgeReportService } from "../src/edge/launch-agent.ts";
import type { EdgeCredential } from "../src/edge/store.ts";

const relayInfo: RelayInfo = {
  instance_id: "relay_test",
  mode: "self_hosted",
  version: "0.1.0",
  api_versions: [1],
  auth_methods: ["bearer"],
  capabilities: {
    realtime: false,
    persistent_snapshots: true,
    instant_device_revocation: true,
    history: false,
    multi_tenant: false,
  },
};

const pairing: PairingCreateResponse = {
  device_code: "synthetic-device-code",
  user_code: "TEST-CODE",
  expires_at: "2026-08-03T10:10:00Z",
  poll_interval_seconds: 5,
};

const issued: PairingTokenIssuedResponse = {
  device_id: "device_test",
  device_token: "synthetic-issued-token",
};

describe("edge command arguments", () => {
  it("renders edge help without using runtime dependencies", async () => {
    const capture = captureOutput();
    const dependencies = fakeDependencies();

    expect(await runEdgeCommand(["--help"], capture.output, dependencies)).toBe(0);
    expect(capture.stdout.join("\n")).toContain("quotacli edge pair");
    expect(capture.stdout.join("\n")).toContain("quotacli edge start");
    expect(capture.stdout.join("\n")).toContain("quotacli edge status");
    expect(capture.stdout.join("\n")).toContain("quotacli edge stop");
    expect(dependencies.createClient).not.toHaveBeenCalled();
    expect(dependencies.store.load).not.toHaveBeenCalled();
  });

  it.each([
    { args: [] },
    { args: ["unknown"] },
    { args: ["pair", "--unknown"] },
    { args: ["pair", "--relay"] },
    { args: ["pair", "--relay", "--other"] },
    {
      args: ["pair", "--relay", "https://one.example", "--relay", "https://two.example"],
    },
    { args: ["unpair", "extra"] },
    { args: ["report", "extra"] },
    { args: ["start", "extra"] },
    { args: ["status", "extra"] },
    { args: ["stop", "extra"] },
    { args: ["--help", "extra"] },
  ])("rejects invalid arguments %#", async ({ args }) => {
    const capture = captureOutput();
    const dependencies = fakeDependencies();

    expect(await runEdgeCommand(args, capture.output, dependencies)).toBe(2);
    expect(capture.stderr.join("\n")).toContain("QuotaCLI edge");
    expect(dependencies.createClient).not.toHaveBeenCalled();
  });

  it("rejects an invalid Relay URL before reading credentials", async () => {
    const capture = captureOutput();
    const dependencies = fakeDependencies();

    expect(
      await runEdgeCommand(
        ["pair", "--relay", "https://relay.example.com/path?secret=value"],
        capture.output,
        dependencies,
      ),
    ).toBe(2);
    expect(dependencies.store.load).not.toHaveBeenCalled();
    expect(dependencies.createClient).not.toHaveBeenCalled();
    expect(capture.stderr.join("\n")).not.toContain("secret=value");
  });
});

describe("edge pair", () => {
  it("uses the default Relay URL", async () => {
    const capture = captureOutput();
    const dependencies = fakeDependencies();

    expect(await runEdgeCommand(["pair"], capture.output, dependencies)).toBe(0);
    expect(dependencies.createClient).toHaveBeenCalledWith("https://quota.gotry.io");
  });

  it("does no network work when a local credential already exists", async () => {
    const capture = captureOutput();
    const dependencies = fakeDependencies({ existing: credential() });

    expect(await runEdgeCommand(["pair"], capture.output, dependencies)).toBe(1);
    expect(dependencies.createClient).not.toHaveBeenCalled();
    expect(dependencies.store.save).not.toHaveBeenCalled();
    expect(capture.stderr.join("\n")).toContain("quotacli edge unpair");
  });

  it("completes pending pairing and saves a Relay-bound credential without printing secrets", async () => {
    let now = Date.parse("2026-08-03T10:00:00Z");
    let saved: EdgeCredential | undefined;
    const fetchMock = vi
      .fn<RelayFetch>()
      .mockResolvedValueOnce(jsonResponse(relayInfo))
      .mockResolvedValueOnce(jsonResponse(pairing, 201))
      .mockResolvedValueOnce(jsonResponse({ status: "pending", poll_interval_seconds: 7 }, 202))
      .mockResolvedValueOnce(jsonResponse(issued));
    const store: EdgeCredentialStoreContract = {
      load: vi.fn(async () => null),
      save: vi.fn(async (value) => {
        saved = value;
      }),
      delete: vi.fn(async () => undefined),
    };
    const createClient = vi.fn(
      (relayUrl: string) =>
        new RelayClient(relayUrl, {
          fetch: fetchMock,
          now: () => new Date(now),
          sleep: async (milliseconds) => {
            now += milliseconds;
          },
        }),
    );
    const longHostname = `  remote-edge-${"x".repeat(200)}  `;
    const dependencies: EdgeCommandDependencies = {
      createClient,
      store,
      platform: "darwin",
      service: fakeService(),
      now: () => new Date(now),
      deviceName: () => longHostname,
      collect: vi.fn(async () => syntheticReport()),
    };
    const capture = captureOutput();

    expect(
      await runEdgeCommand(
        ["pair", "--relay", "https://relay.example.com/"],
        capture.output,
        dependencies,
      ),
    ).toBe(0);

    expect(createClient).toHaveBeenCalledWith("https://relay.example.com");
    expect(saved).toEqual({
      relay_url: "https://relay.example.com",
      instance_id: relayInfo.instance_id,
      device_id: issued.device_id,
      device_token: issued.device_token,
      paired_at: "2026-08-03T10:00:12.000Z",
      last_sequence: -1,
    });
    const createBody = JSON.parse(String(fetchMock.mock.calls[1]?.[1]?.body)) as {
      device_display_name: string;
    };
    expect(createBody.device_display_name).toBe(longHostname.trim().slice(0, 128));
    expect(createBody.device_display_name).toHaveLength(128);

    const rendered = [...capture.stdout, ...capture.stderr].join("\n");
    expect(rendered).toContain(pairing.user_code);
    expect(rendered).toContain(pairing.expires_at);
    expect(rendered).toContain("QuotaBar");
    expect(rendered).not.toContain(pairing.device_code);
    expect(rendered).not.toContain(issued.device_token);
    expect(rendered).not.toContain("Authorization");
    expect(dependencies.service.start).not.toHaveBeenCalled();
    expect(dependencies.service.status).not.toHaveBeenCalled();
    expect(dependencies.service.stop).not.toHaveBeenCalled();
  });

  it("prints only a fixed RelayClientError message", async () => {
    const capture = captureOutput();
    const dependencies = fakeDependencies({
      discoverError: new RelayClientError("unavailable", "The Relay request failed."),
    });

    expect(await runEdgeCommand(["pair"], capture.output, dependencies)).toBe(1);
    expect(capture.stderr).toEqual(["The Relay request failed."]);
    expect(capture.stderr.join("\n")).not.toMatch(/synthetic-device-code|synthetic-issued-token/);
  });

  it("does not print unexpected error details", async () => {
    const capture = captureOutput();
    const dependencies = fakeDependencies({
      discoverError: new Error("Bearer synthetic-issued-token raw Relay body"),
    });

    expect(await runEdgeCommand(["pair"], capture.output, dependencies)).toBe(1);
    expect(capture.stderr).toEqual(["QuotaCLI could not complete edge pairing."]);
  });
});

describe("edge unpair", () => {
  it("revokes the bound remote device before deleting its local credential", async () => {
    const capture = captureOutput();
    const existing = credential();
    const dependencies = fakeDependencies({ existing });

    expect(await runEdgeCommand(["unpair"], capture.output, dependencies)).toBe(0);
    expect(dependencies.store.load).toHaveBeenCalledOnce();
    expect(dependencies.createClient).toHaveBeenCalledWith(existing.relay_url);
    expect(dependencies.store.delete).toHaveBeenCalledOnce();
    expect(capture.stdout).toEqual([
      "The remote device was revoked and the local edge credential was removed.",
    ]);
    expect([...capture.stdout, ...capture.stderr].join("\n")).not.toContain(existing.device_token);
  });

  it("is idempotent when no local credential exists", async () => {
    const capture = captureOutput();
    const dependencies = fakeDependencies({ existing: null });

    expect(await runEdgeCommand(["unpair"], capture.output, dependencies)).toBe(0);
    expect(dependencies.createClient).not.toHaveBeenCalled();
    expect(dependencies.store.delete).not.toHaveBeenCalled();
    expect(capture.stdout).toEqual(["This machine is already unpaired."]);
  });
});

function fakeDependencies(
  options: { existing?: EdgeCredential | null; discoverError?: Error } = {},
): EdgeCommandDependencies & {
  createClient: ReturnType<typeof vi.fn<(relayUrl: string) => EdgeRelayClient>>;
  store: {
    load: ReturnType<typeof vi.fn<EdgeCredentialStoreContract["load"]>>;
    save: ReturnType<typeof vi.fn<EdgeCredentialStoreContract["save"]>>;
    delete: ReturnType<typeof vi.fn<EdgeCredentialStoreContract["delete"]>>;
  };
  service: ReturnType<typeof fakeService>;
} {
  const client: EdgeRelayClient = {
    relayUrl: "https://quota.gotry.io",
    discover: vi.fn(async () => {
      if (options.discoverError) {
        throw options.discoverError;
      }
      return relayInfo;
    }),
    createPairing: vi.fn(async () => pairing),
    pollPairing: vi.fn(async () => issued),
    uploadSnapshot: vi.fn(async () => undefined),
    revokeSelf: vi.fn(async () => undefined),
  };
  const createClient = vi.fn<(relayUrl: string) => EdgeRelayClient>((relayUrl) => ({
    ...client,
    relayUrl,
  }));
  return {
    createClient,
    store: {
      load: vi.fn(async () => options.existing ?? null),
      save: vi.fn(async () => undefined),
      delete: vi.fn(async () => undefined),
    },
    platform: "darwin",
    service: fakeService(),
    now: () => new Date("2026-08-03T10:00:00Z"),
    deviceName: () => "synthetic-edge",
    collect: vi.fn(async () => syntheticReport()),
  };
}

function fakeService(): EdgeReportService & {
  start: ReturnType<typeof vi.fn<EdgeReportService["start"]>>;
  status: ReturnType<typeof vi.fn<EdgeReportService["status"]>>;
  stop: ReturnType<typeof vi.fn<EdgeReportService["stop"]>>;
} {
  return {
    start: vi.fn(async () => undefined),
    status: vi.fn(async () => "stopped"),
    stop: vi.fn(async () => undefined),
  };
}

function syntheticReport() {
  return {
    schema_version: 1 as const,
    captured_at: "2026-08-03T10:00:00Z",
    results: [
      {
        provider: "codex" as const,
        outcome: "success" as const,
        snapshots: [
          {
            provider: "codex" as const,
            account: { fingerprint: "codex-test", fingerprint_scope: "global" as const },
            windows: [],
            source: "codex_source",
            status: "available" as const,
            observed_at: "2026-08-03T10:00:00Z",
          },
        ],
      },
    ],
  };
}

function credential(): EdgeCredential {
  return {
    relay_url: "https://relay.example.com",
    instance_id: "relay_test",
    device_id: "device_test",
    device_token: "synthetic-issued-token",
    paired_at: "2026-08-03T10:00:00Z",
    last_sequence: -1,
  };
}

function captureOutput(): {
  stdout: string[];
  stderr: string[];
  output: EdgeCommandOutput;
} {
  const stdout: string[] = [];
  const stderr: string[] = [];
  return {
    stdout,
    stderr,
    output: {
      stdout: (message) => stdout.push(message),
      stderr: (message) => stderr.push(message),
    },
  };
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
