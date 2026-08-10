export function cliParseError(error: unknown): string {
  if (!(error instanceof Error)) return "Invalid command options.";
  const unknown = /^Unknown option '([^']+)'/.exec(error.message);
  if (unknown) return `Unknown option: ${unknown[1]}`;
  const missing = /^Option '([^ ]+) <value>' argument missing$/.exec(error.message);
  if (missing) return `Missing value for ${missing[1]}.`;
  return "Invalid command options.";
}
