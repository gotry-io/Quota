#!/usr/bin/env node
/**
 * Issue Quota Pro redemption codes through Relay.
 *
 *   pnpm issue-codes --campaign beta --duration monthly --count 10
 *   pnpm issue-codes --campaign beta --duration yearly --count 5 --max-redemptions 1 --expires 2026-12-31T00:00:00Z --note launch
 *
 * Reads REDEMPTION_ADMIN_SECRET from the environment and prints one code per line.
 */
const DEFAULT_RELAY = "https://quota.gotry.io";
const DURATIONS = new Set([
  "weekly",
  "monthly",
  "two_month",
  "three_month",
  "six_month",
  "yearly",
  "lifetime",
]);

const args = parseArgs(process.argv.slice(2));
if (
  args.help ||
  args.campaign === undefined ||
  args.duration === undefined ||
  args.count === undefined
) {
  console.error(`Usage: pnpm issue-codes --campaign <name> --duration <${[...DURATIONS].join("|")}> --count <n>
       [--max-redemptions 1] [--expires <ISO instant>] [--note <text>] [--relay ${DEFAULT_RELAY}]`);
  process.exit(args.help ? 0 : 2);
}

if (!DURATIONS.has(args.duration)) {
  console.error(`invalid duration: ${args.duration}`);
  process.exit(1);
}

const count = Number.parseInt(args.count, 10);
if (!Number.isInteger(count) || count < 1 || count > 500) {
  console.error("count must be an integer from 1 to 500");
  process.exit(1);
}

const maxRedemptions = Number.parseInt(args.maxRedemptions ?? "1", 10);
if (!Number.isInteger(maxRedemptions) || maxRedemptions < 1) {
  console.error("max-redemptions must be an integer ≥ 1");
  process.exit(1);
}

const secret = process.env.REDEMPTION_ADMIN_SECRET;
if (!secret) {
  console.error("REDEMPTION_ADMIN_SECRET is not set");
  process.exit(1);
}

const body = {
  campaign: args.campaign,
  duration: args.duration,
  count,
  max_redemptions: maxRedemptions,
  ...(args.expires === undefined ? {} : { expires_at: args.expires }),
  ...(args.note === undefined ? {} : { note: args.note }),
};

const relay = (args.relay ?? DEFAULT_RELAY).replace(/\/+$/, "");
const response = await fetch(`${relay}/api/admin/redemption-codes`, {
  method: "POST",
  headers: {
    Authorization: `Bearer ${secret}`,
    "Content-Type": "application/json",
  },
  body: JSON.stringify(body),
});
const text = await response.text();
if (!response.ok) {
  console.error(`Relay answered ${response.status}: ${text}`);
  process.exit(1);
}
const payload = JSON.parse(text);
if (!Array.isArray(payload.codes)) {
  console.error("Relay response did not include codes");
  process.exit(1);
}
for (const code of payload.codes) {
  console.log(code);
}

function parseArgs(argv) {
  const parsed = { help: false };
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (flag === "-h" || flag === "--help") {
      parsed.help = true;
      continue;
    }
    if (value === undefined || value.startsWith("-")) {
      console.error(`missing value for ${flag}`);
      process.exit(1);
    }
    switch (flag) {
      case "--campaign":
        parsed.campaign = value;
        break;
      case "--duration":
        parsed.duration = value;
        break;
      case "--count":
        parsed.count = value;
        break;
      case "--max-redemptions":
        parsed.maxRedemptions = value;
        break;
      case "--expires":
        parsed.expires = value;
        break;
      case "--note":
        parsed.note = value;
        break;
      case "--relay":
        parsed.relay = value;
        break;
      default:
        console.error(`unknown flag: ${flag}`);
        process.exit(1);
    }
    index += 1;
  }
  return parsed;
}
