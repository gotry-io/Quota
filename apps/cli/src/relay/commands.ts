import { hostname } from "node:os";
import type {
  PairingCreateResponse,
  PairingTokenIssuedResponse,
  QuotaCollectionReport,
  QuotaSnapshotEnvelope,
  RelayInfo,
} from "@gotry-io/quota-protocol";
import {
  PROTOCOL_VERSION,
  QuotaCollectionReportSchema,
  QuotaSnapshotEnvelopeSchema,
} from "@gotry-io/quota-protocol";
import {
  collectionExitCode,
  collectQuotaReport,
  diagnoseProviderSessions,
} from "@gotry-io/quota-provider";
import packageMetadata from "../../package.json" with { type: "json" };
import { RelayClient, RelayClientError } from "./client.ts";
import { MacOSLaunchAgent, type RelayPushService } from "./launch-agent.ts";
import {
  type RelayCredential,
  RelayCredentialStore,
  type SaveRelayCredentialOptions,
} from "./store.ts";
import { canonicalRelayUrl, DEFAULT_RELAY_URL } from "./url.ts";

export interface RelayCommandOutput {
  stdout(message: string): void;
  stderr(message: string): void;
}

export interface RelayCommandClient {
  readonly relayUrl: string;
  discover(): Promise<RelayInfo>;
  createPairing(deviceDisplayName: string): Promise<PairingCreateResponse>;
  pollPairing(pairing: PairingCreateResponse): Promise<PairingTokenIssuedResponse>;
  uploadSnapshot(deviceToken: string, envelope: QuotaSnapshotEnvelope): Promise<void>;
  revokeSelf(deviceToken: string): Promise<void>;
}

export interface RelayCredentialStoreContract {
  load(): Promise<RelayCredential | null>;
  save(credential: RelayCredential, options?: SaveRelayCredentialOptions): Promise<void>;
  delete(): Promise<void>;
}

export interface StatusProviderDiagnostic {
  provider: string;
  available: boolean;
  credential_source: string;
  detail: string;
}

export interface RelayCommandDependencies {
  createClient(relayUrl: string): RelayCommandClient;
  store: RelayCredentialStoreContract;
  platform: NodeJS.Platform;
  service: RelayPushService;
  now(): Date;
  deviceName(): string;
  collect(options: { providers: "all"; clientVersion: string }): Promise<unknown>;
  diagnoseProviders(): Promise<StatusProviderDiagnostic[]>;
}

export async function runRelayCommand(
  args: readonly string[],
  output: RelayCommandOutput,
  dependencies?: RelayCommandDependencies,
): Promise<number> {
  const subcommand = args[0];
  if (subcommand === "--help" || subcommand === "-h") {
    if (args.length !== 1) {
      return usageError("Relay help does not accept options.", output);
    }
    output.stdout(relayUsage());
    return 0;
  }

  if (subcommand === "pair") {
    const parsed = parsePairArguments(args.slice(1));
    if (!parsed.ok) {
      return usageError(parsed.error, output);
    }
    let relayUrl: string;
    try {
      relayUrl = canonicalRelayUrl(parsed.relayUrl);
    } catch {
      return usageError("The --relay value must be a valid Relay origin.", output);
    }
    const resolved = resolveDependencies(dependencies, output);
    return resolved ? await runPair(relayUrl, output, resolved) : 1;
  }

  if (subcommand === "unpair") {
    if (args.length !== 1) {
      return usageError("The relay unpair command does not accept options.", output);
    }
    const resolved = resolveDependencies(dependencies, output);
    return resolved ? await runUnpair(output, resolved) : 1;
  }

  if (subcommand === "push") {
    if (args.length !== 1) {
      return usageError("The relay push command does not accept options.", output);
    }
    const resolved = resolveDependencies(dependencies, output);
    return resolved ? await runPush(output, resolved) : 1;
  }

  return usageError(
    subcommand ? `Unknown relay command: ${subcommand}` : "Missing relay command.",
    output,
  );
}

export function relayUsage(): string {
  return `QuotaCLI relay

Usage:
  quotacli relay pair [--relay <url>]
  quotacli relay push
  quotacli relay unpair
  quotacli relay --help

pair stores a Relay-bound device credential, performs one foreground collection and upload, then
enables macOS background push every 5 minutes. push performs one collection and upload. unpair
stops background push, revokes the remote device, and removes the local credential.`;
}

export async function runStatusCommand(
  output: RelayCommandOutput,
  dependencies?: RelayCommandDependencies,
): Promise<number> {
  const resolved = resolveDependencies(dependencies, output);
  if (!resolved) {
    return 1;
  }

  try {
    const diagnostics = await resolved.diagnoseProviders();
    const credential = await resolved.store.load();
    let background: "loaded" | "stopped" | "unsupported" | "error" = "unsupported";
    if (resolved.platform === "darwin") {
      try {
        background = await resolved.service.status();
      } catch {
        background = "error";
      }
    }

    output.stdout(`CLI version: ${packageMetadata.version}`);
    output.stdout("Providers:");
    if (diagnostics.length === 0) {
      output.stdout("  none");
    } else {
      for (const diagnostic of diagnostics) {
        const marker = diagnostic.available ? "found" : "missing";
        output.stdout(
          `  ${diagnostic.provider}\t${marker}\t${diagnostic.credential_source}\t${diagnostic.detail}`,
        );
      }
    }

    output.stdout("Relay:");
    output.stdout(`  Pairing: ${credential ? "paired" : "unpaired"}`);
    if (credential) {
      output.stdout(`  Relay URL: ${credential.relay_url}`);
      output.stdout(`  Device ID: ${credential.device_id}`);
      output.stdout(`  Last sequence: ${credential.last_sequence}`);
    }
    output.stdout(`  Background: ${backgroundLabel(background)}`);

    const providerReady = diagnostics.some((diagnostic) => diagnostic.available);
    // Healthy means: at least one local provider credential, no launchd probe error,
    // and background state matches pairing (loaded iff paired on macOS).
    const backgroundHealthy =
      background !== "error" &&
      (resolved.platform !== "darwin" ||
        (credential ? background === "loaded" : background === "stopped"));
    return providerReady && backgroundHealthy ? 0 : 1;
  } catch {
    output.stderr("QuotaCLI could not inspect local status.");
    return 1;
  }
}

function backgroundLabel(status: "loaded" | "stopped" | "unsupported" | "error"): string {
  switch (status) {
    case "loaded":
      return "loaded (every 5 minutes)";
    case "stopped":
      return "stopped";
    case "unsupported":
      return "unsupported on this platform";
    case "error":
      return "unavailable";
  }
}

async function runPair(
  relayUrl: string,
  output: RelayCommandOutput,
  dependencies: RelayCommandDependencies,
): Promise<number> {
  try {
    if (await dependencies.store.load()) {
      output.stderr(
        "This machine is already paired. Run `quotacli relay unpair` before pairing again.",
      );
      return 1;
    }

    const displayName = dependencies.deviceName().trim().slice(0, 128);
    if (displayName.length === 0) {
      throw new RelayCommandError("QuotaCLI could not determine a device name for pairing.");
    }

    const client = dependencies.createClient(relayUrl);
    const relay = await client.discover();
    const pairing = await client.createPairing(displayName);
    output.stdout(`Pairing code: ${pairing.user_code}`);
    output.stdout(`Expires at: ${pairing.expires_at}`);
    output.stdout("Approve this code in QuotaBar, then keep QuotaCLI running.");

    const issued = await client.pollPairing(pairing);
    await dependencies.store.save({
      relay_url: canonicalRelayUrl(client.relayUrl),
      instance_id: relay.instance_id,
      device_id: issued.device_id,
      device_token: issued.device_token,
      paired_at: dependencies.now().toISOString(),
      last_sequence: -1,
    });
  } catch (error) {
    output.stderr(safeErrorMessage(error, "QuotaCLI could not complete relay pairing."));
    return 1;
  }

  // Foreground first upload so QuotaBar can leave Waiting immediately. LaunchAgent still uses
  // RunAtLoad for login/reboot; pair may therefore push once more when the agent loads.
  const initialPush = await pushOnce(dependencies);
  if (initialPush.kind !== "uploaded") {
    writePushFailure(output, initialPush);
    output.stderr(
      "Pairing was saved, but the initial relay push failed. Run `quotacli relay push` before retrying background setup.",
    );
    return 1;
  }
  writePushSuccess(output, initialPush);

  if (dependencies.platform === "darwin") {
    try {
      await dependencies.service.start();
      output.stdout("Pairing complete. Background relay push is loaded and runs every 5 minutes.");
      return initialPush.complete ? 0 : 1;
    } catch {
      output.stderr(
        "Pairing and the initial upload were saved, but QuotaCLI could not start background relay push. Run `quotacli relay unpair` before retrying.",
      );
      return 1;
    }
  }

  output.stdout(
    "Pairing complete. Background relay push is supported only on macOS; recurring uploads require `quotacli relay push`.",
  );
  return initialPush.complete ? 0 : 1;
}

async function runUnpair(
  output: RelayCommandOutput,
  dependencies: RelayCommandDependencies,
): Promise<number> {
  if (dependencies.platform === "darwin") {
    try {
      await dependencies.service.stop();
    } catch {
      output.stderr("QuotaCLI could not stop background relay push. Pairing was retained.");
      return 1;
    }
  }

  let credential: RelayCredential | null;
  try {
    credential = await dependencies.store.load();
  } catch {
    output.stderr("QuotaCLI could not read the local relay credential.");
    return 1;
  }
  if (!credential) {
    output.stdout("This machine is already unpaired.");
    return 0;
  }

  try {
    const client = dependencies.createClient(credential.relay_url);
    const relay = await client.discover();
    if (relay.instance_id !== credential.instance_id) {
      output.stderr(
        "The paired Relay identity does not match the discovered Relay. The local credential was retained.",
      );
      return 1;
    }
    await client.revokeSelf(credential.device_token);
  } catch {
    output.stderr(
      "QuotaCLI could not revoke the remote device. The local credential was retained for retry.",
    );
    return 1;
  }

  try {
    await dependencies.store.delete();
  } catch {
    output.stderr(
      "The remote device was revoked, but QuotaCLI could not remove the local relay credential.",
    );
    return 1;
  }
  output.stdout("The remote device was revoked and the local relay credential was removed.");
  return 0;
}

async function runPush(
  output: RelayCommandOutput,
  dependencies: RelayCommandDependencies,
): Promise<number> {
  const result = await pushOnce(dependencies);
  if (result.kind !== "uploaded") {
    writePushFailure(output, result);
    return 1;
  }
  writePushSuccess(output, result);
  return result.complete ? 0 : 1;
}

type PushOnceResult =
  | { kind: "not_paired" }
  | { kind: "instance_mismatch" }
  | { kind: "failed"; message: string }
  | {
      kind: "uploaded";
      snapshotCount: number;
      sequence: number;
      complete: boolean;
    };

function writePushSuccess(
  output: RelayCommandOutput,
  result: Extract<PushOnceResult, { kind: "uploaded" }>,
): void {
  output.stdout(
    `Uploaded ${result.snapshotCount} ${
      result.snapshotCount === 1 ? "snapshot" : "snapshots"
    } with sequence ${result.sequence}.`,
  );
  if (!result.complete) {
    output.stderr("The snapshot was uploaded, but provider collection was incomplete.");
  }
}

function writePushFailure(
  output: RelayCommandOutput,
  result: Exclude<PushOnceResult, { kind: "uploaded" }>,
): void {
  switch (result.kind) {
    case "not_paired":
      output.stderr("This machine is not paired. Run `quotacli relay pair` first.");
      return;
    case "instance_mismatch":
      output.stderr("The paired Relay identity does not match the discovered Relay.");
      return;
    case "failed":
      output.stderr(result.message);
  }
}

async function pushOnce(dependencies: RelayCommandDependencies): Promise<PushOnceResult> {
  try {
    const credential = await dependencies.store.load();
    if (!credential) {
      return { kind: "not_paired" };
    }

    const client = dependencies.createClient(credential.relay_url);
    const relay = await client.discover();
    if (relay.instance_id !== credential.instance_id) {
      return { kind: "instance_mismatch" };
    }

    const collected = await dependencies.collect({
      providers: "all",
      clientVersion: packageMetadata.version,
    });
    const parsedReport = QuotaCollectionReportSchema.safeParse(collected);
    if (!parsedReport.success) {
      throw new RelayCommandError("QuotaCLI produced an invalid normalized quota report.");
    }
    const report = parsedReport.data;
    const sequence = credential.last_sequence + 1;
    const parsedEnvelope = QuotaSnapshotEnvelopeSchema.safeParse({
      schema_version: PROTOCOL_VERSION,
      device_id: credential.device_id,
      sequence,
      captured_at: report.captured_at,
      snapshots: successSnapshots(report),
    });
    if (!parsedEnvelope.success) {
      throw new RelayCommandError("QuotaCLI could not create a valid snapshot envelope.");
    }

    await client.uploadSnapshot(credential.device_token, parsedEnvelope.data);
    try {
      await dependencies.store.save(
        { ...credential, last_sequence: sequence },
        { overwrite: true },
      );
    } catch {
      throw new RelayCommandError(
        "The snapshot was uploaded, but QuotaCLI could not save the local sequence.",
      );
    }

    return {
      kind: "uploaded",
      snapshotCount: parsedEnvelope.data.snapshots.length,
      sequence,
      complete: collectionExitCode(report) === 0,
    };
  } catch (error) {
    return {
      kind: "failed",
      message: safeErrorMessage(error, "QuotaCLI could not complete the relay push."),
    };
  }
}

function successSnapshots(report: QuotaCollectionReport) {
  return report.results.flatMap((result) => (result.outcome === "success" ? result.snapshots : []));
}

interface ParsedPairArguments {
  ok: true;
  relayUrl: string;
}

interface ParsedPairArgumentsError {
  ok: false;
  error: string;
}

function parsePairArguments(
  args: readonly string[],
): ParsedPairArguments | ParsedPairArgumentsError {
  let relayUrl = DEFAULT_RELAY_URL;
  let hasRelayOption = false;

  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (argument !== "--relay") {
      return { ok: false, error: `Unknown relay pair option: ${argument ?? ""}` };
    }
    if (hasRelayOption) {
      return { ok: false, error: "The --relay option may be provided only once." };
    }
    const value = args[++index];
    if (!value || value.startsWith("-")) {
      return { ok: false, error: "Missing value for --relay." };
    }
    relayUrl = value;
    hasRelayOption = true;
  }

  return { ok: true, relayUrl };
}

function usageError(message: string, output: RelayCommandOutput): 2 {
  output.stderr(`${message}\n\n${relayUsage()}`);
  return 2;
}

function safeErrorMessage(error: unknown, fallback: string): string {
  if (error instanceof RelayClientError || error instanceof RelayCommandError) {
    return error.message;
  }
  return fallback;
}

class RelayCommandError extends Error {}

function resolveDependencies(
  dependencies: RelayCommandDependencies | undefined,
  output: RelayCommandOutput,
): RelayCommandDependencies | null {
  try {
    return dependencies ?? defaultDependencies();
  } catch {
    output.stderr("QuotaCLI could not initialize relay commands.");
    return null;
  }
}

function defaultDependencies(): RelayCommandDependencies {
  return {
    createClient: (relayUrl) => new RelayClient(relayUrl),
    store: new RelayCredentialStore(),
    platform: process.platform,
    service: new MacOSLaunchAgent(),
    now: () => new Date(),
    deviceName: () => hostname(),
    collect: collectQuotaReport,
    diagnoseProviders: () => diagnoseProviderSessions({ probeKeychain: true }),
  };
}
