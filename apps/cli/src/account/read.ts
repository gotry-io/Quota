import { parseArgs } from "node:util";
import type { UsageCostMode } from "@gotry-io/quota-protocol";
import type { CliOutput } from "../commands.ts";
import { cliParseError } from "../arguments.ts";
import { renderJson } from "../render.ts";
import { AccountClient } from "./client.ts";
import { activeSessionWithFreshToken } from "./session.ts";
import { AccountStateStore, AccountStateStoreError } from "./state.ts";

export interface AccountReadDependencies {
  client: Pick<AccountClient, "accountSummary" | "refreshSession">;
  store: AccountStateStore;
  now(): Date;
}

export async function runAccountCommand(
  args: readonly string[],
  output: CliOutput,
  dependencies?: AccountReadDependencies,
): Promise<number> {
  if (args[0] !== "summary") {
    output.stderr(
      `${args[0] ? `Unknown account command: ${args[0]}` : "Missing account command."}\n\n${accountReadUsage()}`,
    );
    return 2;
  }
  const parsed = parseSummaryArguments(args.slice(1));
  if (!parsed.ok) {
    output.stderr(`${parsed.error}\n\n${accountReadUsage()}`);
    return 2;
  }
  try {
    const resolved = dependencies ?? {
      client: new AccountClient(),
      store: new AccountStateStore(),
      now: () => new Date(),
    };
    const session = await activeSessionWithFreshToken(
      resolved.store,
      resolved.client,
      "account",
      resolved.now(),
    );
    const query = new URLSearchParams({ cost_mode: parsed.costMode });
    if (parsed.from) query.set("from", parsed.from);
    if (parsed.to) query.set("to", parsed.to);
    if (parsed.deviceId) query.set("device_id", parsed.deviceId);
    const summary = await resolved.client.accountSummary(
      session.account.access_token,
      query.toString(),
    );
    output.stdout(renderJson(summary, parsed.pretty));
    return 0;
  } catch (error) {
    output.stderr(
      error instanceof AccountStateStoreError && error.code === "client_upgrade_required"
        ? error.message
        : "QuotaCLI could not read the account summary. Sign in with `quotacli login` and retry.",
    );
    return 1;
  }
}

type SummaryArguments =
  | {
      ok: true;
      from?: string;
      to?: string;
      deviceId?: string;
      costMode: UsageCostMode;
      pretty: boolean;
    }
  | { ok: false; error: string };

function parseSummaryArguments(args: readonly string[]): SummaryArguments {
  let values: {
    from?: string;
    to?: string;
    "device-id"?: string;
    "cost-mode"?: string;
    format?: string;
    pretty?: boolean;
  };
  try {
    values = parseArgs({
      args: [...args],
      options: {
        from: { type: "string" },
        to: { type: "string" },
        "device-id": { type: "string" },
        "cost-mode": { type: "string" },
        format: { type: "string" },
        pretty: { type: "boolean" },
      },
      strict: true,
      allowPositionals: false,
    }).values;
  } catch (error) {
    return { ok: false, error: cliParseError(error) };
  }
  const { from, to } = values;
  const deviceId = values["device-id"];
  const costModeValue = values["cost-mode"] ?? "calculate";
  if (from !== undefined && !/^\d{4}-\d{2}-\d{2}$/.test(from)) {
    return { ok: false, error: "Invalid --from date." };
  }
  if (to !== undefined && !/^\d{4}-\d{2}-\d{2}$/.test(to)) {
    return { ok: false, error: "Invalid --to date." };
  }
  if (deviceId !== undefined && (deviceId.length > 128 || deviceId.trim() !== deviceId)) {
    return { ok: false, error: "Invalid --device-id value." };
  }
  if (!(["calculate", "auto", "reported"] as const).includes(costModeValue as UsageCostMode)) {
    return { ok: false, error: "Invalid --cost-mode value." };
  }
  if (values.format !== undefined && values.format !== "json") {
    return { ok: false, error: "Account summary supports --format json." };
  }
  if (from && to && from > to) return { ok: false, error: "--from must not be after --to." };
  return {
    ok: true,
    ...(from === undefined ? {} : { from }),
    ...(to === undefined ? {} : { to }),
    ...(deviceId === undefined ? {} : { deviceId }),
    costMode: costModeValue as UsageCostMode,
    pretty: values.pretty ?? false,
  };
}

export function accountReadUsage(): string {
  return "Usage: quotacli account summary [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--device-id <id>] [--cost-mode calculate|auto|reported] [--format json] [--pretty]";
}
