import { afterEach, describe, expect, it, vi } from "vitest";
import {
  type EdgeCommandDependencies,
  type EdgeCommandOutput,
  runEdgeCommand,
} from "../src/edge/commands.ts";
import type { EdgeReportService } from "../src/edge/launch-agent.ts";
import type { EdgeCredential } from "../src/edge/store.ts";

const pairedCredential: EdgeCredential = {
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

describe("edge background service commands", () => {
  it("starts only after confirming a paired credential", async () => {
    const dependencies = serviceDependencies();
    const capture = captureOutput();

    expect(await runEdgeCommand(["start"], capture.output, dependencies)).toBe(0);
    expect(dependencies.store.load).toHaveBeenCalledOnce();
    expect(dependencies.service.start).toHaveBeenCalledOnce();
    expect(capture.stdout).toEqual([
      "Background edge reporting is loaded and scheduled every 5 minutes.",
    ]);
  });

  it("does not touch launchd or files when start is unpaired", async () => {
    const dependencies = serviceDependencies({ credential: null });
    const capture = captureOutput();

    expect(await runEdgeCommand(["start"], capture.output, dependencies)).toBe(1);
    expect(dependencies.service.start).not.toHaveBeenCalled();
    expect(dependencies.service.status).not.toHaveBeenCalled();
    expect(dependencies.service.stop).not.toHaveBeenCalled();
    expect(capture.stderr).toEqual(["This machine is not paired. Run `quotacli edge pair` first."]);
  });

  it("hides unexpected start errors", async () => {
    const dependencies = serviceDependencies({
      startError: new Error(`launchctl output ${pairedCredential.device_token}`),
    });
    const capture = captureOutput();

    expect(await runEdgeCommand(["start"], capture.output, dependencies)).toBe(1);
    expect(capture.stderr).toEqual(["QuotaCLI could not start background edge reporting."]);
    expect(capture.stderr.join("\n")).not.toContain(pairedCredential.device_token);
  });

  it("shows paired identity and returns zero only for a loaded service", async () => {
    const dependencies = serviceDependencies({ status: "loaded" });
    const capture = captureOutput();

    expect(await runEdgeCommand(["status"], capture.output, dependencies)).toBe(0);
    expect(capture.stdout).toEqual([
      "Pairing: paired",
      `Relay URL: ${pairedCredential.relay_url}`,
      `Device ID: ${pairedCredential.device_id}`,
      `Last sequence: ${pairedCredential.last_sequence}`,
      "Service: loaded",
    ]);
    expect([...capture.stdout, ...capture.stderr].join("\n")).not.toContain(
      pairedCredential.device_token,
    );
  });

  it.each([
    { credential: pairedCredential, status: "stopped" as const, pairing: "paired" },
    { credential: null, status: "loaded" as const, pairing: "unpaired" },
  ])("returns one unless both paired and loaded %#", async ({ credential, status, pairing }) => {
    const dependencies = serviceDependencies({ credential, status });
    const capture = captureOutput();

    expect(await runEdgeCommand(["status"], capture.output, dependencies)).toBe(1);
    expect(capture.stdout).toContain(`Pairing: ${pairing}`);
    expect(capture.stdout).toContain(`Service: ${status}`);
  });

  it("hides unexpected status errors", async () => {
    const dependencies = serviceDependencies({
      statusError: new Error(`raw print output ${pairedCredential.device_token}`),
    });
    const capture = captureOutput();

    expect(await runEdgeCommand(["status"], capture.output, dependencies)).toBe(1);
    expect(capture.stderr).toEqual(["QuotaCLI could not inspect background edge reporting."]);
    expect(capture.stderr.join("\n")).not.toContain(pairedCredential.device_token);
  });

  it("stops the service without reading or deleting pairing", async () => {
    const dependencies = serviceDependencies();
    const capture = captureOutput();

    expect(await runEdgeCommand(["stop"], capture.output, dependencies)).toBe(0);
    expect(dependencies.service.stop).toHaveBeenCalledOnce();
    expect(dependencies.store.load).not.toHaveBeenCalled();
    expect(dependencies.store.delete).not.toHaveBeenCalled();
    expect(capture.stdout).toEqual(["Background edge reporting is stopped. Pairing was retained."]);
  });

  it("hides unexpected stop errors and retains pairing", async () => {
    const dependencies = serviceDependencies({
      stopError: new Error(`raw bootout output ${pairedCredential.device_token}`),
    });
    const capture = captureOutput();

    expect(await runEdgeCommand(["stop"], capture.output, dependencies)).toBe(1);
    expect(dependencies.store.delete).not.toHaveBeenCalled();
    expect(capture.stderr).toEqual(["QuotaCLI could not stop background edge reporting."]);
    expect(capture.stderr.join("\n")).not.toContain(pairedCredential.device_token);
  });

  it("stops the macOS service before deleting the credential during unpair", async () => {
    const events: string[] = [];
    const dependencies = serviceDependencies({ events });

    expect(await runEdgeCommand(["unpair"], captureOutput().output, dependencies)).toBe(0);
    expect(events).toEqual(["stop", "load", "discover", "revoke", "delete"]);
  });

  it("retains pairing and does no remote work when service stop fails", async () => {
    const events: string[] = [];
    const dependencies = serviceDependencies({
      events,
      stopError: new Error(`raw bootout output ${pairedCredential.device_token}`),
    });
    const capture = captureOutput();

    expect(await runEdgeCommand(["unpair"], capture.output, dependencies)).toBe(1);
    expect(events).toEqual(["stop"]);
    expect(dependencies.store.load).not.toHaveBeenCalled();
    expect(dependencies.store.delete).not.toHaveBeenCalled();
    expect(capture.stderr).toEqual([
      "QuotaCLI could not stop background edge reporting. Pairing was retained.",
    ]);
    expect(capture.stderr.join("\n")).not.toContain(pairedCredential.device_token);
  });

  it("leaves the background service alone when unpairing outside macOS", async () => {
    const events: string[] = [];
    const dependencies = serviceDependencies({ platform: "linux", events });

    expect(await runEdgeCommand(["unpair"], captureOutput().output, dependencies)).toBe(0);
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

    expect(await runEdgeCommand(["unpair"], capture.output, dependencies)).toBe(1);
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

    expect(await runEdgeCommand(["unpair"], capture.output, dependencies)).toBe(1);
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

    expect(await runEdgeCommand(["unpair"], capture.output, dependencies)).toBe(1);
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

    expect(await runEdgeCommand(["unpair"], capture.output, dependencies)).toBe(1);
    expect(events).toEqual(["stop", "load", "discover", "revoke", "delete"]);
    expect(capture.stderr).toEqual([
      "The remote device was revoked, but QuotaCLI could not remove the local edge credential.",
    ]);
    expect(capture.stderr.join("\n")).not.toContain(pairedCredential.device_token);
  });

  it.each(["start", "status", "stop"])(
    "returns a safe unsupported-platform error for %s",
    async (command) => {
      const dependencies = serviceDependencies({ platform: "linux" });
      const capture = captureOutput();

      expect(await runEdgeCommand([command], capture.output, dependencies)).toBe(1);
      expect(capture.stderr).toEqual(["Background edge reporting is supported only on macOS."]);
      expect(dependencies.store.load).not.toHaveBeenCalled();
      expect(dependencies.store.delete).not.toHaveBeenCalled();
      expect(dependencies.service.start).not.toHaveBeenCalled();
      expect(dependencies.service.status).not.toHaveBeenCalled();
      expect(dependencies.service.stop).not.toHaveBeenCalled();
    },
  );

  it("reports default dependency construction failures without throwing", async () => {
    vi.stubEnv("XDG_CONFIG_HOME", "relative/config");
    const capture = captureOutput();

    expect(await runEdgeCommand(["report"], capture.output)).toBe(1);
    expect(capture.stderr).toEqual(["QuotaCLI could not initialize edge commands."]);
  });

  it("keeps invalid Relay URLs as usage errors before dependency construction", async () => {
    vi.stubEnv("XDG_CONFIG_HOME", "relative/config");
    const capture = captureOutput();

    expect(
      await runEdgeCommand(
        ["pair", "--relay", "https://relay.example.com/path?secret=value"],
        capture.output,
      ),
    ).toBe(2);
    expect(capture.stderr.join("\n")).toContain("The --relay value must be a valid Relay origin.");
    expect(capture.stderr.join("\n")).not.toContain("secret=value");
    expect(capture.stderr).not.toContain("QuotaCLI could not initialize edge commands.");
  });
});

interface ServiceDependencyOptions {
  credential?: EdgeCredential | null;
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

function serviceDependencies(options: ServiceDependencyOptions = {}): EdgeCommandDependencies & {
  store: {
    load: ReturnType<typeof vi.fn<EdgeCommandDependencies["store"]["load"]>>;
    save: ReturnType<typeof vi.fn<EdgeCommandDependencies["store"]["save"]>>;
    delete: ReturnType<typeof vi.fn<EdgeCommandDependencies["store"]["delete"]>>;
  };
  service: {
    start: ReturnType<typeof vi.fn<EdgeReportService["start"]>>;
    status: ReturnType<typeof vi.fn<EdgeReportService["status"]>>;
    stop: ReturnType<typeof vi.fn<EdgeReportService["stop"]>>;
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
          version: "0.1.0",
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
    deviceName: () => "synthetic-edge",
    collect: vi.fn(async () => undefined),
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
