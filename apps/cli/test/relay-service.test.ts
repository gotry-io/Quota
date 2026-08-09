import { afterEach, describe, expect, it, vi } from "vitest";
import packageMetadata from "../package.json" with { type: "json" };
import {
  type RelayCommandDependencies,
  type RelayCommandOutput,
  runRelayCommand,
  runDoctorCommand,
} from "../src/relay/commands.ts";
import type { RelayPushService } from "../src/relay/launch-agent.ts";
import type { RelayCredential } from "../src/relay/store.ts";

const pairedCredential: RelayCredential = {
  relay_url: "https://relay.example.com",
  instance_id: "relay_test",
  device_id: "device_test",
  device_token: "synthetic-secret-device-token",
  paired_at: "2026-08-03T10:00:00Z",
  last_sequence: 12,
};

afterEach(() => {
  vi.unstubAllEnvs();
});

describe("relay background lifecycle", () => {
  it("starts background push as part of pair, not as a separate command", async () => {
    const dependencies = serviceDependencies({ credential: null });
    const capture = captureOutput();

    expect(await runRelayCommand(["start"], capture.output, dependencies)).toBe(2);
    expect(dependencies.service.start).not.toHaveBeenCalled();
    expect(capture.stderr.join("\n")).toContain("Unknown relay command: start");
  });

  it("removes the stop command from the relay surface", async () => {
    const dependencies = serviceDependencies();
    const capture = captureOutput();

    expect(await runRelayCommand(["stop"], capture.output, dependencies)).toBe(2);
    expect(dependencies.service.stop).not.toHaveBeenCalled();
    expect(capture.stderr.join("\n")).toContain("Unknown relay command: stop");
  });

  it("shows paired identity through doctor and hides the device token", async () => {
    const dependencies = serviceDependencies({ status: "loaded" });
    const capture = captureOutput();

    expect(await runDoctorCommand(capture.output, dependencies)).toBe(0);
    expect(capture.stdout).toEqual([
      `CLI version: ${packageMetadata.version}`,
      "Providers:",
      "  codex\tfound\t~/.codex/auth.json",
      "Relay:",
      "  Pairing: paired",
      `  Relay URL: ${pairedCredential.relay_url}`,
      `  Device ID: ${pairedCredential.device_id}`,
      `  Last sequence: ${pairedCredential.last_sequence}`,
      "  Background: loaded (every 5 minutes)",
    ]);
    expect([...capture.stdout, ...capture.stderr].join("\n")).not.toContain(
      pairedCredential.device_token,
    );
  });

  it.each([
    { credential: pairedCredential, status: "stopped" as const, pairing: "paired", code: 1 },
    { credential: null, status: "loaded" as const, pairing: "unpaired", code: 1 },
    { credential: null, status: "stopped" as const, pairing: "unpaired", code: 0 },
    { credential: pairedCredential, status: "loaded" as const, pairing: "paired", code: 0 },
  ])(
    "returns health based on providers and expected background state %#",
    async ({ credential, status, pairing, code }) => {
      const dependencies = serviceDependencies({ credential, status });
      const capture = captureOutput();

      expect(await runDoctorCommand(capture.output, dependencies)).toBe(code);
      expect(capture.stdout).toContain(`  Pairing: ${pairing}`);
      expect(capture.stdout.join("\n")).toContain(`Background: ${status}`);
    },
  );

  it("hides unexpected doctor errors", async () => {
    const dependencies = serviceDependencies({
      statusError: new Error(`raw print output ${pairedCredential.device_token}`),
    });
    const capture = captureOutput();

    expect(await runDoctorCommand(capture.output, dependencies)).toBe(1);
    expect(capture.stdout.join("\n")).toContain("Background: unavailable");
    expect(capture.stderr.join("\n")).not.toContain(pairedCredential.device_token);
  });

  it("stops the macOS service before deleting the credential during unpair", async () => {
    const events: string[] = [];
    const dependencies = serviceDependencies({ events });

    expect(await runRelayCommand(["unpair"], captureOutput().output, dependencies)).toBe(0);
    expect(events).toEqual(["stop", "load", "discover", "revoke", "delete"]);
  });

  it("retains pairing and does no remote work when service stop fails", async () => {
    const events: string[] = [];
    const dependencies = serviceDependencies({
      events,
      stopError: new Error(`raw bootout output ${pairedCredential.device_token}`),
    });
    const capture = captureOutput();

    expect(await runRelayCommand(["unpair"], capture.output, dependencies)).toBe(1);
    expect(events).toEqual(["stop"]);
    expect(dependencies.store.load).not.toHaveBeenCalled();
    expect(dependencies.store.delete).not.toHaveBeenCalled();
    expect(capture.stderr).toEqual([
      "QuotaCLI could not stop background relay push. Pairing was retained.",
    ]);
    expect(capture.stderr.join("\n")).not.toContain(pairedCredential.device_token);
  });

  it("leaves the background service alone when unpairing outside macOS", async () => {
    const events: string[] = [];
    const dependencies = serviceDependencies({ platform: "linux", events });

    expect(await runRelayCommand(["unpair"], captureOutput().output, dependencies)).toBe(0);
    expect(dependencies.service.stop).not.toHaveBeenCalled();
    expect(events).toEqual(["load", "discover", "revoke", "delete"]);
    expect(dependencies.store.delete).toHaveBeenCalledOnce();
  });

  it("retains the credential when Relay discovery fails", async () => {
    const events: string[] = [];
    const dependencies = serviceDependencies({
      events,
      discoverError: new Error(`raw Relay response ${pairedCredential.device_token}`),
    });
    const capture = captureOutput();

    expect(await runRelayCommand(["unpair"], capture.output, dependencies)).toBe(1);
    expect(events).toEqual(["stop", "load", "discover"]);
    expect(dependencies.store.delete).not.toHaveBeenCalled();
    expect(capture.stderr).toEqual([
      "QuotaCLI could not revoke the remote device. The local credential was retained for retry.",
    ]);
    expect(capture.stderr.join("\n")).not.toContain(pairedCredential.device_token);
  });

  it("retains the credential when the discovered Relay instance does not match", async () => {
    const events: string[] = [];
    const dependencies = serviceDependencies({ events, relayInstanceID: "relay_other" });
    const capture = captureOutput();

    expect(await runRelayCommand(["unpair"], capture.output, dependencies)).toBe(1);
    expect(events).toEqual(["stop", "load", "discover"]);
    expect(dependencies.store.delete).not.toHaveBeenCalled();
    expect(capture.stderr).toEqual([
      "The paired Relay identity does not match the discovered Relay. The local credential was retained.",
    ]);
  });

  it("retains the credential when remote self-revocation fails", async () => {
    const events: string[] = [];
    const dependencies = serviceDependencies({
      events,
      revokeError: new Error(`Bearer ${pairedCredential.device_token} raw Relay body`),
    });
    const capture = captureOutput();

    expect(await runRelayCommand(["unpair"], capture.output, dependencies)).toBe(1);
    expect(events).toEqual(["stop", "load", "discover", "revoke"]);
    expect(dependencies.store.delete).not.toHaveBeenCalled();
    expect(capture.stderr).toEqual([
      "QuotaCLI could not revoke the remote device. The local credential was retained for retry.",
    ]);
    expect(capture.stderr.join("\n")).not.toContain(pairedCredential.device_token);
  });

  it("reports local deletion failure after remote revocation", async () => {
    const events: string[] = [];
    const dependencies = serviceDependencies({
      events,
      deleteError: new Error(`delete failed ${pairedCredential.device_token}`),
    });
    const capture = captureOutput();

    expect(await runRelayCommand(["unpair"], capture.output, dependencies)).toBe(1);
    expect(events).toEqual(["stop", "load", "discover", "revoke", "delete"]);
    expect(capture.stderr).toEqual([
      "The remote device was revoked, but QuotaCLI could not remove the local relay credential.",
    ]);
    expect(capture.stderr.join("\n")).not.toContain(pairedCredential.device_token);
  });

  it("reports default dependency construction failures without throwing", async () => {
    vi.stubEnv("XDG_CONFIG_HOME", "relative/config");
    const capture = captureOutput();

    expect(await runRelayCommand(["push"], capture.output)).toBe(1);
    expect(capture.stderr).toEqual(["QuotaCLI could not initialize relay commands."]);
  });

  it("keeps invalid Relay URLs as usage errors before dependency construction", async () => {
    vi.stubEnv("XDG_CONFIG_HOME", "relative/config");
    const capture = captureOutput();

    expect(
      await runRelayCommand(
        ["pair", "--relay", "https://relay.example.com/path?secret=value"],
        capture.output,
      ),
    ).toBe(2);
    expect(capture.stderr.join("\n")).toContain("The --relay value must be a valid Relay origin.");
    expect(capture.stderr.join("\n")).not.toContain("secret=value");
    expect(capture.stderr).not.toContain("QuotaCLI could not initialize relay commands.");
  });
});

interface ServiceDependencyOptions {
  credential?: RelayCredential | null;
  platform?: NodeJS.Platform;
  status?: "loaded" | "stopped";
  startError?: Error;
  statusError?: Error;
  stopError?: Error;
  discoverError?: Error;
  revokeError?: Error;
  deleteError?: Error;
  relayInstanceID?: string;
  events?: string[];
}

function serviceDependencies(options: ServiceDependencyOptions = {}): RelayCommandDependencies & {
  store: {
    load: ReturnType<typeof vi.fn<RelayCommandDependencies["store"]["load"]>>;
    save: ReturnType<typeof vi.fn<RelayCommandDependencies["store"]["save"]>>;
    delete: ReturnType<typeof vi.fn<RelayCommandDependencies["store"]["delete"]>>;
  };
  service: {
    start: ReturnType<typeof vi.fn<RelayPushService["start"]>>;
    status: ReturnType<typeof vi.fn<RelayPushService["status"]>>;
    stop: ReturnType<typeof vi.fn<RelayPushService["stop"]>>;
  };
} {
  const events = options.events;
  return {
    createClient: vi.fn((relayUrl: string) => ({
      relayUrl,
      discover: vi.fn(async () => {
        events?.push("discover");
        if (options.discoverError) {
          throw options.discoverError;
        }
        return {
          instance_id: options.relayInstanceID ?? pairedCredential.instance_id,
          mode: "self_hosted" as const,
          version: "0.0.1",
          api_versions: [1 as const],
          auth_methods: ["bearer" as const],
          capabilities: {
            realtime: false,
            persistent_snapshots: true,
            instant_device_revocation: true,
            history: false,
            multi_tenant: false,
          },
        };
      }),
      createPairing: vi.fn(async () => {
        throw new Error("not used");
      }),
      pollPairing: vi.fn(async () => {
        throw new Error("not used");
      }),
      uploadSnapshot: vi.fn(async () => undefined),
      revokeSelf: vi.fn(async (deviceToken: string) => {
        events?.push("revoke");
        expect(deviceToken).toBe(pairedCredential.device_token);
        if (options.revokeError) {
          throw options.revokeError;
        }
      }),
    })),
    store: {
      load: vi.fn(async () => {
        events?.push("load");
        return options.credential === undefined ? pairedCredential : options.credential;
      }),
      save: vi.fn(async () => undefined),
      delete: vi.fn(async () => {
        events?.push("delete");
        if (options.deleteError) {
          throw options.deleteError;
        }
      }),
    },
    platform: options.platform ?? "darwin",
    service: {
      start: vi.fn(async () => {
        if (options.startError) {
          throw options.startError;
        }
      }),
      status: vi.fn(async () => {
        if (options.statusError) {
          throw options.statusError;
        }
        return options.status ?? "stopped";
      }),
      stop: vi.fn(async () => {
        events?.push("stop");
        if (options.stopError) {
          throw options.stopError;
        }
      }),
    },
    now: () => new Date("2026-08-03T10:00:00Z"),
    deviceName: () => "synthetic-relay",
    collect: vi.fn(async () => undefined),
    diagnoseProviders: vi.fn(async () => [
      {
        provider: "codex" as const,
        available: true,
        credential_source: "~/.codex/auth.json",
      },
    ]),
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
