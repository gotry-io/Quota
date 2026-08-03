import type {
  PairingCreateResponse,
  PairingTokenIssuedResponse,
  QuotaCollectionReport,
  QuotaSnapshot,
  QuotaSnapshotEnvelope,
  RelayInfo,
} from "@gotry-io/quota-protocol";
import { describe, expect, it, vi } from "vitest";
import packageMetadata from "../package.json" with { type: "json" };
import { RelayClient, RelayClientError, type RelayFetch } from "../src/edge/client.ts";
import {
  type EdgeCommandDependencies,
  type EdgeCommandOutput,
  type EdgeCredentialStoreContract,
  type EdgeRelayClient,
  runEdgeCommand,
} from "../src/edge/commands.ts";
import type { EdgeCredential } from "../src/edge/store.ts";

const boundCredential: EdgeCredential = {
  relay_url: "https://relay.example.com",
  instance_id: "relay_bound",
  device_id: "device_test",
  device_token: "synthetic-device-token",
  paired_at: "2026-08-03T10:00:00Z",
  last_sequence: 4,
};

const boundRelay: RelayInfo = {
  instance_id: boundCredential.instance_id,
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

describe("edge report", () => {
  it("does no discovery, collection, or upload when the machine is not paired", async () => {
    const capture = captureOutput();
    const dependencies = reportDependencies({ credential: null });

    expect(await runEdgeCommand(["report"], capture.output, dependencies)).toBe(1);
    expect(dependencies.createClient).not.toHaveBeenCalled();
    expect(dependencies.collect).not.toHaveBeenCalled();
    expect(dependencies.store.save).not.toHaveBeenCalled();
    expect(capture.stderr).toEqual(["This machine is not paired. Run `quotacli edge pair` first."]);
  });

  it("discovers without Authorization and stops before collection on instance mismatch", async () => {
    const fetchMock = vi.fn<RelayFetch>(async (_input, init) => {
      expect(new Headers(init?.headers).has("Authorization")).toBe(false);
      return jsonResponse({ ...boundRelay, instance_id: "relay_other" });
    });
    const dependencies = reportDependencies({
      createClient: (relayUrl) => new RelayClient(relayUrl, { fetch: fetchMock }),
    });
    const capture = captureOutput();

    expect(await runEdgeCommand(["report"], capture.output, dependencies)).toBe(1);
    expect(fetchMock).toHaveBeenCalledOnce();
    expect(dependencies.collect).not.toHaveBeenCalled();
    expect(dependencies.store.save).not.toHaveBeenCalled();
    const rendered = [...capture.stdout, ...capture.stderr].join("\n");
    expect(rendered).toContain("paired Relay identity does not match");
    expect(rendered).not.toContain(boundCredential.device_token);
  });

  it("flattens successful snapshots in report order and commits sequence only after upload", async () => {
    const events: string[] = [];
    const uploaded: QuotaSnapshotEnvelope[] = [];
    const report = completeReport();
    const dependencies = reportDependencies({
      report,
      upload: async (token, envelope) => {
        expect(token).toBe(boundCredential.device_token);
        events.push("upload");
        uploaded.push(envelope);
      },
      save: async () => {
        events.push("save");
      },
    });
    const capture = captureOutput();

    expect(await runEdgeCommand(["report"], capture.output, dependencies)).toBe(0);
    expect(dependencies.collect).toHaveBeenCalledWith({
      providers: "all",
      clientVersion: packageMetadata.version,
    });
    expect(dependencies.createClient).toHaveBeenCalledWith(boundCredential.relay_url);
    expect(events).toEqual(["upload", "save"]);
    expect(uploaded).toEqual([
      {
        schema_version: 1,
        device_id: boundCredential.device_id,
        sequence: 5,
        captured_at: report.captured_at,
        snapshots: report.results.flatMap((result) => result.snapshots),
      },
    ]);
    expect(dependencies.store.save).toHaveBeenCalledWith(
      { ...boundCredential, last_sequence: 5 },
      { overwrite: true },
    );
    expect(capture.stdout).toEqual(["Uploaded 3 snapshots with sequence 5."]);
    expect(capture.stderr).toEqual([]);
  });

  it("uploads an empty heartbeat and reports incomplete collection", async () => {
    let uploaded: QuotaSnapshotEnvelope | undefined;
    const dependencies = reportDependencies({
      report: emptyHeartbeatReport(),
      upload: async (_token, envelope) => {
        uploaded = envelope;
      },
    });
    const capture = captureOutput();

    expect(await runEdgeCommand(["report"], capture.output, dependencies)).toBe(1);
    expect(uploaded?.snapshots).toEqual([]);
    expect(uploaded?.sequence).toBe(5);
    expect(capture.stdout).toEqual(["Uploaded 0 snapshots with sequence 5."]);
    expect(capture.stderr).toEqual([
      "The snapshot was uploaded, but provider collection was incomplete.",
    ]);
  });

  it("uploads successful provider snapshots but exits 1 for a partial collection", async () => {
    let uploaded: QuotaSnapshotEnvelope | undefined;
    const report = partialReport();
    const dependencies = reportDependencies({
      report,
      upload: async (_token, envelope) => {
        uploaded = envelope;
      },
    });
    const capture = captureOutput();

    expect(await runEdgeCommand(["report"], capture.output, dependencies)).toBe(1);
    expect(uploaded?.snapshots.map((snapshot) => snapshot.provider)).toEqual(["codex", "grok"]);
    expect(dependencies.store.save).toHaveBeenCalledWith(
      { ...boundCredential, last_sequence: 5 },
      { overwrite: true },
    );
    expect(capture.stderr.join("\n")).toContain("uploaded");
    expect(capture.stderr.join("\n")).toContain("incomplete");
  });

  it("does not save sequence when upload is rejected by a revoked credential", async () => {
    const dependencies = reportDependencies({
      upload: async () => {
        throw new RelayClientError("unauthorized", "The Relay rejected the request.");
      },
    });
    const capture = captureOutput();

    expect(await runEdgeCommand(["report"], capture.output, dependencies)).toBe(1);
    expect(dependencies.store.save).not.toHaveBeenCalled();
    expect(capture.stderr).toEqual(["The Relay rejected the request."]);
  });

  it("does not expose unexpected upload errors or save sequence", async () => {
    const dependencies = reportDependencies({
      upload: async () => {
        throw new Error(
          `Authorization Bearer ${boundCredential.device_token} raw Relay response body`,
        );
      },
    });
    const capture = captureOutput();

    expect(await runEdgeCommand(["report"], capture.output, dependencies)).toBe(1);
    expect(dependencies.store.save).not.toHaveBeenCalled();
    expect(capture.stderr).toEqual(["QuotaCLI could not complete the edge report."]);
    expect(capture.stderr.join("\n")).not.toMatch(/Authorization|raw Relay|synthetic-device-token/);
  });

  it("does not expose a credential when local sequence persistence fails", async () => {
    const dependencies = reportDependencies({
      save: async () => {
        throw new Error(`save failed for ${boundCredential.device_token}`);
      },
    });
    const capture = captureOutput();

    expect(await runEdgeCommand(["report"], capture.output, dependencies)).toBe(1);
    expect(capture.stderr).toEqual([
      "The snapshot was uploaded, but QuotaCLI could not save the local sequence.",
    ]);
    expect(capture.stderr.join("\n")).not.toContain(boundCredential.device_token);
  });

  it("retries the same sequence when the prior 204 was not committed locally", async () => {
    const uploadedSequences: number[] = [];
    let saveAttempts = 0;
    const dependencies = reportDependencies({
      upload: async (_token, envelope) => {
        uploadedSequences.push(envelope.sequence);
      },
      save: async () => {
        saveAttempts += 1;
        if (saveAttempts === 1) {
          throw new Error("synthetic save failure");
        }
      },
    });

    expect(await runEdgeCommand(["report"], captureOutput().output, dependencies)).toBe(1);
    expect(await runEdgeCommand(["report"], captureOutput().output, dependencies)).toBe(0);
    expect(uploadedSequences).toEqual([5, 5]);
    expect(dependencies.store.save).toHaveBeenNthCalledWith(
      2,
      { ...boundCredential, last_sequence: 5 },
      { overwrite: true },
    );
  });

  it("rejects a malformed report before upload with a fixed error", async () => {
    const upload = vi.fn<EdgeRelayClient["uploadSnapshot"]>(async () => undefined);
    const dependencies = reportDependencies({
      report: {
        ...completeReport(),
        raw_secret: `Authorization Bearer ${boundCredential.device_token}`,
      },
      upload,
    });
    const capture = captureOutput();

    expect(await runEdgeCommand(["report"], capture.output, dependencies)).toBe(1);
    expect(upload).not.toHaveBeenCalled();
    expect(capture.stderr).toEqual(["QuotaCLI produced an invalid normalized quota report."]);
    expect(capture.stderr.join("\n")).not.toContain(boundCredential.device_token);
  });

  it("does not expose unexpected collection errors", async () => {
    const dependencies = reportDependencies({
      collectError: new Error(`raw provider body ${boundCredential.device_token}`),
    });
    const capture = captureOutput();

    expect(await runEdgeCommand(["report"], capture.output, dependencies)).toBe(1);
    expect(capture.stderr).toEqual(["QuotaCLI could not complete the edge report."]);
    expect(capture.stderr.join("\n")).not.toContain(boundCredential.device_token);
  });
});

interface ReportDependencyOptions {
  credential?: EdgeCredential | null;
  report?: unknown;
  collectError?: Error;
  createClient?: (relayUrl: string) => EdgeRelayClient;
  upload?: (token: string, envelope: QuotaSnapshotEnvelope) => Promise<void>;
  save?: EdgeCredentialStoreContract["save"];
}

function reportDependencies(options: ReportDependencyOptions = {}): EdgeCommandDependencies & {
  createClient: ReturnType<typeof vi.fn<(relayUrl: string) => EdgeRelayClient>>;
  collect: ReturnType<typeof vi.fn<EdgeCommandDependencies["collect"]>>;
  store: {
    load: ReturnType<typeof vi.fn<EdgeCredentialStoreContract["load"]>>;
    save: ReturnType<typeof vi.fn<EdgeCredentialStoreContract["save"]>>;
    delete: ReturnType<typeof vi.fn<EdgeCredentialStoreContract["delete"]>>;
  };
} {
  const client = relayClient(options.upload);
  const createClient = vi.fn<(relayUrl: string) => EdgeRelayClient>(
    options.createClient ?? (() => client),
  );
  const collect = vi.fn<EdgeCommandDependencies["collect"]>(async () => {
    if (options.collectError) {
      throw options.collectError;
    }
    return options.report ?? completeReport();
  });
  return {
    createClient,
    store: {
      load: vi.fn(async () =>
        options.credential === undefined ? boundCredential : options.credential,
      ),
      save: vi.fn(options.save ?? (async () => undefined)),
      delete: vi.fn(async () => undefined),
    },
    now: () => new Date("2026-08-03T10:00:00Z"),
    deviceName: () => "synthetic-edge",
    collect,
  };
}

function relayClient(upload: ReportDependencyOptions["upload"]): EdgeRelayClient & {
  uploadSnapshot: ReturnType<typeof vi.fn<EdgeRelayClient["uploadSnapshot"]>>;
} {
  return {
    relayUrl: boundCredential.relay_url,
    discover: vi.fn(async () => boundRelay),
    createPairing: vi.fn(async () => pairing()),
    pollPairing: vi.fn(async () => issued()),
    uploadSnapshot: vi.fn(upload ?? (async () => undefined)),
  };
}

function completeReport(): QuotaCollectionReport {
  return {
    schema_version: 1,
    captured_at: "2026-08-03T10:05:00Z",
    results: [successResult("codex"), successResult("claude"), successResult("grok")],
  };
}

function partialReport(): QuotaCollectionReport {
  return {
    schema_version: 1,
    captured_at: "2026-08-03T10:05:00Z",
    results: [
      successResult("codex"),
      {
        provider: "claude",
        outcome: "auth_required",
        snapshots: [],
        message: "Synthetic missing session.",
      },
      successResult("grok"),
    ],
  };
}

function emptyHeartbeatReport(): QuotaCollectionReport {
  return {
    schema_version: 1,
    captured_at: "2026-08-03T10:05:00Z",
    results: ["codex", "claude", "grok"].map((provider) => ({
      provider: provider as "codex" | "claude" | "grok",
      outcome: "auth_required" as const,
      snapshots: [],
      message: "Synthetic missing session.",
    })),
  };
}

function successResult(provider: "codex" | "claude" | "grok") {
  return {
    provider,
    outcome: "success" as const,
    snapshots: [snapshot(provider)],
    source: `${provider}_source`,
  };
}

function snapshot(provider: "codex" | "claude" | "grok"): QuotaSnapshot {
  return {
    provider,
    account: { fingerprint: `${provider}-test`, fingerprint_scope: "global" },
    windows: [],
    source: `${provider}_source`,
    status: "available",
    observed_at: "2026-08-03T10:04:00Z",
  };
}

function pairing(): PairingCreateResponse {
  return {
    device_code: "synthetic-device-code",
    user_code: "TEST-CODE",
    expires_at: "2026-08-03T10:10:00Z",
    poll_interval_seconds: 5,
  };
}

function issued(): PairingTokenIssuedResponse {
  return { device_id: boundCredential.device_id, device_token: boundCredential.device_token };
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
