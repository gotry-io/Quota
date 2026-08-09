import { afterEach, describe, expect, it, vi } from "vitest";
import {
  type RelayCommandDependencies,
  type RelayCommandOutput,
  runRelayCommand,
} from "../src/relay/commands.ts";
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

describe("relay lifecycle", () => {
  it.each(["start", "stop"])("does not expose a separate %s command", async (command) => {
    const dependencies = lifecycleDependencies();
    const capture = captureOutput();

    expect(await runRelayCommand([command], capture.output, dependencies)).toBe(2);
    expect(dependencies.cleanupLegacyService).not.toHaveBeenCalled();
    expect(capture.stderr.join("\n")).toContain(`Unknown relay command: ${command}`);
  });

  it("cleans up the shipped macOS service before revoking and deleting the credential", async () => {
    const events: string[] = [];
    const dependencies = lifecycleDependencies({ events });

    expect(await runRelayCommand(["unpair"], captureOutput().output, dependencies)).toBe(0);
    expect(events).toEqual(["cleanup", "load", "discover", "revoke", "delete"]);
  });

  it("retains pairing when legacy service cleanup fails", async () => {
    const events: string[] = [];
    const dependencies = lifecycleDependencies({
      events,
      cleanupError: new Error(`raw launchctl output ${pairedCredential.device_token}`),
    });
    const capture = captureOutput();

    expect(await runRelayCommand(["unpair"], capture.output, dependencies)).toBe(1);
    expect(events).toEqual(["cleanup"]);
    expect(dependencies.store.load).not.toHaveBeenCalled();
    expect(capture.stderr).toEqual([
      "QuotaCLI could not remove the legacy background task. Pairing was retained.",
    ]);
    expect(capture.stderr.join("\n")).not.toContain(pairedCredential.device_token);
  });

  it("does not run macOS cleanup on other platforms", async () => {
    const events: string[] = [];
    const dependencies = lifecycleDependencies({ platform: "linux", events });

    expect(await runRelayCommand(["unpair"], captureOutput().output, dependencies)).toBe(0);
    expect(events).toEqual(["load", "discover", "revoke", "delete"]);
    expect(dependencies.cleanupLegacyService).not.toHaveBeenCalled();
  });

  it("retains the credential when Relay discovery fails", async () => {
    const events: string[] = [];
    const dependencies = lifecycleDependencies({
      events,
      discoverError: new Error(`raw Relay response ${pairedCredential.device_token}`),
    });
    const capture = captureOutput();

    expect(await runRelayCommand(["unpair"], capture.output, dependencies)).toBe(1);
    expect(events).toEqual(["cleanup", "load", "discover"]);
    expect(dependencies.store.delete).not.toHaveBeenCalled();
    expect(capture.stderr).toEqual([
      "QuotaCLI could not revoke the remote device. The local credential was retained for retry.",
    ]);
    expect(capture.stderr.join("\n")).not.toContain(pairedCredential.device_token);
  });

  it("retains the credential when the Relay instance changed", async () => {
    const events: string[] = [];
    const dependencies = lifecycleDependencies({ events, relayInstanceID: "relay_other" });
    const capture = captureOutput();

    expect(await runRelayCommand(["unpair"], capture.output, dependencies)).toBe(1);
    expect(events).toEqual(["cleanup", "load", "discover"]);
    expect(dependencies.store.delete).not.toHaveBeenCalled();
    expect(capture.stderr).toEqual([
      "The paired Relay identity does not match the discovered Relay. The local credential was retained.",
    ]);
  });

  it("retains the credential when remote self-revocation fails", async () => {
    const events: string[] = [];
    const dependencies = lifecycleDependencies({
      events,
      revokeError: new Error(`Bearer ${pairedCredential.device_token} raw Relay body`),
    });
    const capture = captureOutput();

    expect(await runRelayCommand(["unpair"], capture.output, dependencies)).toBe(1);
    expect(events).toEqual(["cleanup", "load", "discover", "revoke"]);
    expect(dependencies.store.delete).not.toHaveBeenCalled();
    expect(capture.stderr.join("\n")).not.toContain(pairedCredential.device_token);
  });

  it("reports local deletion failure after remote revocation", async () => {
    const events: string[] = [];
    const dependencies = lifecycleDependencies({
      events,
      deleteError: new Error(`delete failed ${pairedCredential.device_token}`),
    });
    const capture = captureOutput();

    expect(await runRelayCommand(["unpair"], capture.output, dependencies)).toBe(1);
    expect(events).toEqual(["cleanup", "load", "discover", "revoke", "delete"]);
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
});

interface LifecycleDependencyOptions {
  platform?: NodeJS.Platform;
  cleanupError?: Error;
  discoverError?: Error;
  revokeError?: Error;
  deleteError?: Error;
  relayInstanceID?: string;
  events?: string[];
}

function lifecycleDependencies(
  options: LifecycleDependencyOptions = {},
): RelayCommandDependencies & {
  store: {
    load: ReturnType<typeof vi.fn<RelayCommandDependencies["store"]["load"]>>;
    save: ReturnType<typeof vi.fn<RelayCommandDependencies["store"]["save"]>>;
    delete: ReturnType<typeof vi.fn<RelayCommandDependencies["store"]["delete"]>>;
  };
  cleanupLegacyService: ReturnType<typeof vi.fn<RelayCommandDependencies["cleanupLegacyService"]>>;
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
        return pairedCredential;
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
    cleanupLegacyService: vi.fn(async () => {
      events?.push("cleanup");
      if (options.cleanupError) {
        throw options.cleanupError;
      }
    }),
    now: () => new Date("2026-08-03T10:00:00Z"),
    deviceName: () => "synthetic-relay",
    collect: vi.fn(async () => undefined),
    diagnoseProviders: vi.fn(async () => []),
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
