/**
 * Protocol-v2 compatibility for the released QuotaCLI 0.0.5 outbox.
 *
 * The wire schema must decode the literal model sentinel so a pending submission can drain.
 * Collectors and Relay storage discard it; remove this boundary with the 0.0.8 compatibility
 * cleanup after the 0.0.6/0.0.7 retention window.
 */
export const RELEASED_UNKNOWN_USAGE_MODEL = "unknown" as const;
export const RELEASED_USAGE_PARSER_REVISION = "quota-usage-4" as const;

export function isReleasedUnknownUsageModel(value: string): boolean {
  return value === RELEASED_UNKNOWN_USAGE_MODEL;
}

export function acceptsReleasedUnknownUsageModel(parserRevision: string, model: string): boolean {
  return !isReleasedUnknownUsageModel(model) || parserRevision === RELEASED_USAGE_PARSER_REVISION;
}
