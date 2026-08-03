import { hostname } from "node:os";
import type {
  PairingCreateResponse,
  PairingTokenIssuedResponse,
  RelayInfo,
} from "@gotry-io/quota-protocol";
import { RelayClient, RelayClientError } from "./client.ts";
import { type EdgeCredential, EdgeCredentialStore } from "./store.ts";
import { canonicalRelayUrl, DEFAULT_RELAY_URL } from "./url.ts";

export interface EdgeCommandOutput {
  stdout(message: string): void;
  stderr(message: string): void;
}

export interface EdgePairingClient {
  readonly relayUrl: string;
  discover(): Promise<RelayInfo>;
  createPairing(deviceDisplayName: string): Promise<PairingCreateResponse>;
  pollPairing(pairing: PairingCreateResponse): Promise<PairingTokenIssuedResponse>;
}

export interface EdgeCredentialStoreContract {
  load(): Promise<EdgeCredential | null>;
  save(credential: EdgeCredential): Promise<void>;
  delete(): Promise<void>;
}

export interface EdgeCommandDependencies {
  createClient(relayUrl: string): EdgePairingClient;
  store: EdgeCredentialStoreContract;
  now(): Date;
  deviceName(): string;
}

export async function runEdgeCommand(
  args: readonly string[],
  output: EdgeCommandOutput,
  dependencies?: EdgeCommandDependencies,
): Promise<number> {
  const subcommand = args[0];
  if (subcommand === "--help" || subcommand === "-h") {
    if (args.length !== 1) {
      return usageError("Edge help does not accept options.", output);
    }
    output.stdout(edgeUsage());
    return 0;
  }

  if (subcommand === "pair") {
    const parsed = parsePairArguments(args.slice(1));
    if (!parsed.ok) {
      return usageError(parsed.error, output);
    }
    return await runPair(parsed.relayUrl, output, dependencies ?? defaultDependencies());
  }

  if (subcommand === "unpair") {
    if (args.length !== 1) {
      return usageError("The edge unpair command does not accept options.", output);
    }
    return await runUnpair(output, dependencies ?? defaultDependencies());
  }

  return usageError(
    subcommand ? `Unknown edge command: ${subcommand}` : "Missing edge command.",
    output,
  );
}

export function edgeUsage(): string {
  return `QuotaCLI edge pairing

Usage:
  quotacli edge pair [--relay <url>]
  quotacli edge unpair
  quotacli edge --help

Pairing stores a Relay-bound device credential but does not start recurring quota reporting.`;
}

async function runPair(
  requestedRelayUrl: string,
  output: EdgeCommandOutput,
  dependencies: EdgeCommandDependencies,
): Promise<number> {
  try {
    let relayUrl: string;
    try {
      relayUrl = canonicalRelayUrl(requestedRelayUrl);
    } catch {
      return usageError("The --relay value must be a valid Relay origin.", output);
    }

    if (await dependencies.store.load()) {
      output.stderr(
        "This machine is already paired. Run `quotacli edge unpair` before pairing again.",
      );
      return 1;
    }

    const displayName = dependencies.deviceName().trim().slice(0, 128);
    if (displayName.length === 0) {
      throw new EdgeCommandError("QuotaCLI could not determine a device name for pairing.");
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
    output.stdout("Pairing complete. Recurring edge reporting has not been started.");
    return 0;
  } catch (error) {
    output.stderr(safeErrorMessage(error));
    return 1;
  }
}

async function runUnpair(
  output: EdgeCommandOutput,
  dependencies: EdgeCommandDependencies,
): Promise<number> {
  try {
    await dependencies.store.delete();
    output.stdout("The local edge credential was removed if it existed.");
    output.stdout(
      "The remote device was not revoked. Revoke it in QuotaBar or Relay device management.",
    );
    return 0;
  } catch {
    output.stderr("QuotaCLI could not remove the local edge credential.");
    return 1;
  }
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
      return { ok: false, error: `Unknown edge pair option: ${argument ?? ""}` };
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

function usageError(message: string, output: EdgeCommandOutput): 2 {
  output.stderr(`${message}\n\n${edgeUsage()}`);
  return 2;
}

function safeErrorMessage(error: unknown): string {
  if (error instanceof RelayClientError || error instanceof EdgeCommandError) {
    return error.message;
  }
  return "QuotaCLI could not complete edge pairing.";
}

class EdgeCommandError extends Error {}

function defaultDependencies(): EdgeCommandDependencies {
  return {
    createClient: (relayUrl) => new RelayClient(relayUrl),
    store: new EdgeCredentialStore(),
    now: () => new Date(),
    deviceName: () => hostname(),
  };
}
