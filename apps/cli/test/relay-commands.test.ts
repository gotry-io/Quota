import type {
  PairingCreateResponse,
  PairingTokenIssuedResponse,
  RelayInfo,
} from "@gotry-io/quota-protocol";
import { describe, expect, it, vi } from "vitest";
import { RelayClient, RelayClientError, type RelayFetch } from "../src/relay/client.ts";
import {
  type RelayCommandClient,
  type RelayCommandDependencies,
  type RelayCommandOutput,
  type RelayCredentialStoreContract,
  runRelayCommand,
  runStatusCommand,
} from "../src/relay/commands.ts";
import type { RelayPushService } from "../src/relay/launch-agent.ts";
import type { RelayCredential } from "../src/relay/store.ts";

const relayInfo: RelayInfo = {
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

describe("relay command arguments", () => {
  it("renders relay help without using runtime dependencies", async () => {
    const capture = captureOutput();
    const dependencies = fakeDependencies();

    expect(await runRelayCommand(["--help"], capture.output, dependencies)).toBe(0);
    expect(capture.stdout.join("\n")).toContain("quotacli relay pair");
    expect(capture.stdout.join("\n")).toContain("quotacli relay push");
    expect(capture.stdout.join("\n")).toContain("quotacli relay unpair");
    expect(capture.stdout.join("\n")).not.toContain("relay start");
    expect(capture.stdout.join("\n")).not.toContain("relay stop");
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
    { args: ["push", "extra"] },
    { args: ["start"] },
    { args: ["stop"] },
    { args: ["status"] },
    { args: ["report"] },
    { args: ["--help", "extra"] },
  ])("rejects invalid arguments %#", async ({ args }) => {
    const capture = captureOutput();
    const dependencies = fakeDependencies();

    expect(await runRelayCommand(args, capture.output, dependencies)).toBe(2);
    expect(capture.stderr.join("\n")).toContain("QuotaCLI relay");
    expect(dependencies.createClient).not.toHaveBeenCalled();
  });

  it("rejects an invalid Relay URL before reading credentials", async () => {
    const capture = captureOutput();
    const dependencies = fakeDependencies();

    expect(
      await runRelayCommand(
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

describe("relay pair", () => {
  it("uses the default Relay URL and starts background push without an in-process upload", async () => {
    const capture = captureOutput();
    const dependencies = fakeDependencies();

    expect(await runRelayCommand(["pair"], capture.output, dependencies)).toBe(0);
    expect(dependencies.createClient).toHaveBeenCalledWith("https://quota.gotry.io");
    expect(dependencies.service.start).toHaveBeenCalledOnce();
    expect(dependencies.collect).not.toHaveBeenCalled();
    expect(capture.stdout.join("\n")).toContain(
      "Background relay push is loaded, runs immediately, and every 5 minutes.",
    );
  });

  it("does no network work when a local credential already exists", async () => {
    const capture = captureOutput();
    const dependencies = fakeDependencies({ existing: credential() });

    expect(await runRelayCommand(["pair"], capture.output, dependencies)).toBe(1);
    expect(dependencies.createClient).not.toHaveBeenCalled();
    expect(dependencies.store.save).not.toHaveBeenCalled();
    expect(dependencies.service.start).not.toHaveBeenCalled();
    expect(capture.stderr.join("\n")).toContain("quotacli relay unpair");
  });

  it("completes pending pairing and saves a Relay-bound credential without printing secrets", async () => {
    let now = Date.parse("2026-08-03T10:00:00Z");
    let saved: RelayCredential | undefined;
    const fetchMock = vi
      .fn<RelayFetch>()
      .mockResolvedValueOnce(jsonResponse(relayInfo))
      .mockResolvedValueOnce(jsonResponse(pairing, 201))
      .mockResolvedValueOnce(jsonResponse({ status: "pending", poll_interval_seconds: 7 }, 202))
      .mockResolvedValueOnce(jsonResponse(issued));
    const store: RelayCredentialStoreContract = {
      load: vi.fn(async () => (saved ? { ...saved } : null)),
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
    const longHostname = `  remote-relay-${"x".repeat(200)}  `;
    const dependencies: RelayCommandDependencies = {
      createClient,
      store,
      platform: "darwin",
      service: fakeService(),
      now: () => new Date(now),
      deviceName: () => longHostname,
      collect: vi.fn(async () => syntheticReport()),
      diagnoseProviders: vi.fn(async () => []),
    };
    const capture = captureOutput();

    expect(
      await runRelayCommand(
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
    expect(dependencies.service.start).toHaveBeenCalledOnce();
    expect(dependencies.collect).not.toHaveBeenCalled();
    expect(dependencies.service.stop).not.toHaveBeenCalled();
  });

  it("keeps the credential when background start fails after pairing", async () => {
    const capture = captureOutput();
    const dependencies = fakeDependencies({
      startError: new Error("launchctl failed"),
    });

    expect(await runRelayCommand(["pair"], capture.output, dependencies)).toBe(1);
    expect(dependencies.store.save).toHaveBeenCalledOnce();
    expect(dependencies.collect).not.toHaveBeenCalled();
    expect(capture.stderr.join("\n")).toContain("could not start background relay push");
    expect(capture.stderr.join("\n")).toContain("quotacli relay unpair");
  });

  it("pairs without background support outside macOS and does not push automatically", async () => {
    const capture = captureOutput();
    const dependencies = fakeDependencies({ platform: "linux" });

    expect(await runRelayCommand(["pair"], capture.output, dependencies)).toBe(0);
    expect(dependencies.service.start).not.toHaveBeenCalled();
    expect(dependencies.collect).not.toHaveBeenCalled();
    expect(capture.stdout.join("\n")).toContain("Background relay push is supported only on macOS");
  });

  it("prints only a fixed RelayClientError message", async () => {
    const capture = captureOutput();
    const dependencies = fakeDependencies({
      discoverError: new RelayClientError("unavailable", "The Relay request failed."),
    });

    expect(await runRelayCommand(["pair"], capture.output, dependencies)).toBe(1);
    expect(capture.stderr).toEqual(["The Relay request failed."]);
    expect(capture.stderr.join("\n")).not.toMatch(/synthetic-device-code|synthetic-issued-token/);
  });

  it("does not print unexpected error details", async () => {
    const capture = captureOutput();
    const dependencies = fakeDependencies({
      discoverError: new Error("Bearer synthetic-issued-token raw Relay body"),
    });

    expect(await runRelayCommand(["pair"], capture.output, dependencies)).toBe(1);
    expect(capture.stderr).toEqual(["QuotaCLI could not complete relay pairing."]);
  });
});

describe("relay unpair", () => {
  it("revokes the bound remote device before deleting its local credential", async () => {
    const capture = captureOutput();
    const existing = credential();
    const dependencies = fakeDependencies({ existing });

    expect(await runRelayCommand(["unpair"], capture.output, dependencies)).toBe(0);
    expect(dependencies.store.load).toHaveBeenCalledOnce();
    expect(dependencies.createClient).toHaveBeenCalledWith(existing.relay_url);
    expect(dependencies.store.delete).toHaveBeenCalledOnce();
    expect(capture.stdout).toEqual([
      "The remote device was revoked and the local relay credential was removed.",
    ]);
    expect([...capture.stdout, ...capture.stderr].join("\n")).not.toContain(existing.device_token);
  });

  it("is idempotent when no local credential exists", async () => {
    const capture = captureOutput();
    const dependencies = fakeDependencies({ existing: null });

    expect(await runRelayCommand(["unpair"], capture.output, dependencies)).toBe(0);
    expect(dependencies.createClient).not.toHaveBeenCalled();
    expect(dependencies.store.delete).not.toHaveBeenCalled();
    expect(capture.stdout).toEqual(["This machine is already unpaired."]);
  });
});

describe("status", () => {
  it("summarizes providers and unpaired relay state", async () => {
    const capture = captureOutput();
    const dependencies = fakeDependencies({ existing: null, status: "stopped" });

    expect(await runStatusCommand(capture.output, dependencies)).toBe(0);
    expect(capture.stdout).toEqual([
      `CLI version: 0.0.1`,
      "Providers:",
      "  codex\tfound\t~/.codex/auth.json\tCodex auth file",
      "Relay:",
      "  Pairing: unpaired",
      "  Background: stopped",
    ]);
    expect(dependencies.diagnoseProviders).toHaveBeenCalledOnce();
  });

  it("returns non-zero when paired but background reporting is stopped", async () => {
    const capture = captureOutput();
    const dependencies = fakeDependencies({ existing: credential(), status: "stopped" });

    expect(await runStatusCommand(capture.output, dependencies)).toBe(1);
    expect(capture.stdout.join("\n")).toContain("Pairing: paired");
    expect(capture.stdout.join("\n")).toContain("Background: stopped");
    expect(capture.stdout.join("\n")).not.toContain(credential().device_token);
  });

  it("returns non-zero when unpaired but a background agent is still loaded", async () => {
    const capture = captureOutput();
    const dependencies = fakeDependencies({ existing: null, status: "loaded" });

    expect(await runStatusCommand(capture.output, dependencies)).toBe(1);
    expect(capture.stdout.join("\n")).toContain("Pairing: unpaired");
    expect(capture.stdout.join("\n")).toContain("Background: loaded (every 5 minutes)");
  });

  it("marks background support as unsupported outside macOS", async () => {
    const capture = captureOutput();
    const dependencies = fakeDependencies({
      existing: credential(),
      platform: "linux",
    });

    expect(await runStatusCommand(capture.output, dependencies)).toBe(0);
    expect(capture.stdout.join("\n")).toContain("Background: unsupported on this platform");
    expect(dependencies.service.status).not.toHaveBeenCalled();
  });
});

function fakeDependencies(
  options: {
    existing?: RelayCredential | null;
    discoverError?: Error;
    startError?: Error;
    platform?: NodeJS.Platform;
    status?: "loaded" | "stopped";
  } = {},
): RelayCommandDependencies & {
  createClient: ReturnType<typeof vi.fn<(relayUrl: string) => RelayCommandClient>>;
  store: {
    load: ReturnType<typeof vi.fn<RelayCredentialStoreContract["load"]>>;
    save: ReturnType<typeof vi.fn<RelayCredentialStoreContract["save"]>>;
    delete: ReturnType<typeof vi.fn<RelayCredentialStoreContract["delete"]>>;
  };
  service: ReturnType<typeof fakeService>;
  collect: ReturnType<typeof vi.fn<RelayCommandDependencies["collect"]>>;
  diagnoseProviders: ReturnType<typeof vi.fn<RelayCommandDependencies["diagnoseProviders"]>>;
} {
  let saved: RelayCredential | null = options.existing === undefined ? null : options.existing;
  const client: RelayCommandClient = {
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
  const createClient = vi.fn<(relayUrl: string) => RelayCommandClient>((relayUrl) => ({
    ...client,
    relayUrl,
  }));
  return {
    createClient,
    store: {
      load: vi.fn(async () => saved),
      save: vi.fn(async (value) => {
        saved = value;
      }),
      delete: vi.fn(async () => {
        saved = null;
      }),
    },
    platform: options.platform ?? "darwin",
    service: fakeService(
      options.startError === undefined
        ? options.status === undefined
          ? {}
          : { status: options.status }
        : options.status === undefined
          ? { startError: options.startError }
          : { startError: options.startError, status: options.status },
    ),
    now: () => new Date("2026-08-03T10:00:00Z"),
    deviceName: () => "synthetic-relay",
    collect: vi.fn(async () => syntheticReport()),
    diagnoseProviders: vi.fn(async () => [
      {
        provider: "codex",
        available: true,
        credential_source: "~/.codex/auth.json",
        detail: "Codex auth file",
      },
    ]),
  };
}

function fakeService(
  options: { startError?: Error; status?: "loaded" | "stopped" } = {},
): RelayPushService & {
  start: ReturnType<typeof vi.fn<RelayPushService["start"]>>;
  status: ReturnType<typeof vi.fn<RelayPushService["status"]>>;
  stop: ReturnType<typeof vi.fn<RelayPushService["stop"]>>;
} {
  return {
    start: vi.fn(async () => {
      if (options.startError) {
        throw options.startError;
      }
    }),
    status: vi.fn(async () => options.status ?? "stopped"),
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

function credential(): RelayCredential {
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
  output: RelayCommandOutput;
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
