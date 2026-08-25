import {
  type BillingAgent,
  type BillingChannel,
  type ChannelSource,
  type ContextBucket,
  IanaTimezoneSchema,
  type InferenceProvider,
  PROTOCOL_VERSION,
  type PricingCatalog,
  type PricingCatalogEntry,
  PricingCatalogSchema,
  type PricingRates,
  MAXIMUM_MODEL_CATALOG_ALIASES,
  type ModelCatalog,
  ModelCatalogSchema,
  type FingerprintScope,
  type QuotaSnapshot,
  type QuotaStatus,
  Rfc3339InstantSchema,
  type UsageCostAssumption,
  type UsageCostMode,
  type UsageCostOutcome,
  UsageCostOutcomeSchema,
  type UsageHourlyFact,
  UsageHourlyFactSchema,
  type UsageTokenTotals,
  UsageTokenTotalsSchema,
  type UsageUnpricedItem,
  type UsageUnpricedReason,
} from "@gotry-io/quota-protocol";

export function remainingPercent(usedPercent: number): number {
  return Math.max(0, Math.min(100, 100 - usedPercent));
}

/**
 * How long an observation may claim to describe current quota when its own windows say
 * nothing shorter. A device that stops collecting must stop answering for a live account.
 */
export const MAX_SNAPSHOT_VALIDITY_SECONDS = 86_400;

/**
 * The instant this observation stops describing current quota, in epoch milliseconds.
 *
 * The first window reset is the exact boundary: at it that window refills and the number
 * the reading carries is wrong. Windows that report no reset fall back to their own
 * cadence, and every observation ages out at {@link MAX_SNAPSHOT_VALIDITY_SECONDS}.
 *
 * Every input is part of the reading, so each reader derives the same boundary from the
 * snapshot instead of trusting a value stamped onto it. A reader that depended on the
 * stamp presented pre-stamp readings as current forever, which is the failure this
 * derivation removes rather than patches.
 */
export function snapshotValidUntil(snapshot: QuotaSnapshot): number {
  const observed = Date.parse(snapshot.observed_at);
  const limit = observed + MAX_SNAPSHOT_VALIDITY_SECONDS * 1_000;
  const resets: number[] = [];
  const cadences: number[] = [];
  for (const window of snapshot.windows) {
    if (window.resets_at !== undefined) {
      const reset = Date.parse(window.resets_at);
      if (reset > observed) resets.push(reset);
    }
    if (window.duration_seconds !== undefined) {
      cadences.push(observed + window.duration_seconds * 1_000);
    }
  }
  const boundary = resets.length > 0 ? Math.min(...resets) : Math.min(...cadences);
  return Math.min(boundary, limit);
}

export function isSnapshotStale(snapshot: QuotaSnapshot, now = new Date()): boolean {
  // Negated rather than `<=` so a reading this cannot place in time reads as stale: an
  // observation whose boundary is unknown is not one a person should be shown as current.
  return snapshot.status === "stale" || !(snapshotValidUntil(snapshot) > now.getTime());
}

/**
 * The status to show for one account observation.
 *
 * Past the observation's validity boundary the counters no longer describe the account, so
 * a device that stopped collecting reads as stale instead of staying available forever. A
 * status the device already reported stands as reported.
 */
export function observedSnapshotStatus(snapshot: QuotaSnapshot, now = new Date()): QuotaStatus {
  return snapshot.status === "available" && isSnapshotStale(snapshot, now)
    ? "stale"
    : snapshot.status;
}

/**
 * One subscription, addressed the way ADR 0003 addresses it.
 *
 * A `global` fingerprint identifies the same account wherever it was observed, so every
 * device that reported it resolves to one subscription. A `source` fingerprint means
 * nothing outside the source that produced it and therefore carries that source's id.
 */
export interface QuotaSubscriptionIdentity {
  provider: string;
  fingerprint: string;
  scope: FingerprintScope;
  source_id: string | null;
}

/** One device that reported a subscription, kept whether or not its reading is shown. */
export interface QuotaObservationSource {
  device_id: string;
  observed_at: string;
  is_stale: boolean;
}

export interface QuotaObservationInput {
  device_id: string;
  snapshot: QuotaSnapshot;
}

export interface MergedQuotaObservation {
  identity: QuotaSubscriptionIdentity;
  /** The one reading shown for this subscription; the others stay in {@link sources}. */
  snapshot: QuotaSnapshot;
  sources: QuotaObservationSource[];
  selected_device_id: string;
  is_stale: boolean;
}

export function quotaSubscriptionKey(identity: QuotaSubscriptionIdentity): string {
  return [identity.provider, identity.fingerprint, identity.scope, identity.source_id ?? ""].join(
    "\u001f",
  );
}

/**
 * The subscriptions behind a set of account observations, one entry each.
 *
 * Relay keeps one observation per reporting device and never deduplicates, so resolving
 * them is every reader's job. Conflicting readings are not additive measurements: this
 * selects one rather than combining values, and keeps every reporting device attached to
 * the subscription so provenance survives the merge.
 *
 * Selection follows ADR 0003: a valid unexpired reading first, then the newest
 * `observed_at`, then a deterministic device id. QuotaBar inserts locally collected
 * readings ahead of the last step, because local collection is the only authority for the
 * machine in front of you; a reader of uploaded observations has no local source and so
 * cannot reach that step.
 *
 * `updated_at` deliberately takes no part. It records when Relay last wrote the row, which
 * a device re-uploading an unchanged old reading moves without making that reading newer.
 */
export function mergeQuotaObservations(
  observations: readonly QuotaObservationInput[],
  now = new Date(),
): MergedQuotaObservation[] {
  const merged = new Map<string, MergedQuotaObservation>();
  for (const observation of observations) {
    const candidate = subscriptionCandidate(observation, now);
    const key = quotaSubscriptionKey(candidate.identity);
    const existing = merged.get(key);
    if (!existing) {
      merged.set(key, candidate);
      continue;
    }
    if (isBetterObservation(candidate, existing)) {
      existing.snapshot = candidate.snapshot;
      existing.selected_device_id = candidate.selected_device_id;
      existing.is_stale = candidate.is_stale;
    }
    existing.sources.push(...candidate.sources);
  }
  for (const subscription of merged.values()) {
    subscription.sources.sort((left, right) => compareText(left.device_id, right.device_id));
  }
  return [...merged.values()].sort(compareIdentity);
}

function subscriptionCandidate(
  observation: QuotaObservationInput,
  now: Date,
): MergedQuotaObservation {
  const snapshot = observation.snapshot;
  const scope = snapshot.account.fingerprint_scope;
  const isStale = observedSnapshotStatus(snapshot, now) !== "available";
  return {
    identity: {
      provider: snapshot.provider,
      fingerprint: snapshot.account.fingerprint,
      scope,
      source_id: scope === "source" ? observation.device_id : null,
    },
    snapshot,
    sources: [
      {
        device_id: observation.device_id,
        observed_at: snapshot.observed_at,
        is_stale: isStale,
      },
    ],
    selected_device_id: observation.device_id,
    is_stale: isStale,
  };
}

function isBetterObservation(
  incoming: MergedQuotaObservation,
  existing: MergedQuotaObservation,
): boolean {
  if (incoming.is_stale !== existing.is_stale) return !incoming.is_stale;
  const incomingObserved = Date.parse(incoming.snapshot.observed_at);
  const existingObserved = Date.parse(existing.snapshot.observed_at);
  if (incomingObserved !== existingObserved) return incomingObserved > existingObserved;
  return compareText(incoming.selected_device_id, existing.selected_device_id) < 0;
}

function compareIdentity(left: MergedQuotaObservation, right: MergedQuotaObservation): number {
  return (
    compareText(left.identity.provider, right.identity.provider) ||
    compareText(left.identity.fingerprint, right.identity.fingerprint) ||
    compareText(left.identity.scope, right.identity.scope) ||
    compareText(left.identity.source_id ?? "", right.identity.source_id ?? "")
  );
}

function compareText(left: string, right: string): number {
  if (left === right) return 0;
  return left < right ? -1 : 1;
}

export interface NormalizedUsageEvent {
  occurred_at: string;
  agent: BillingAgent;
  model: string;
  billing_channel: BillingChannel;
  channel_source: ChannelSource;
  input_tokens: number;
  cache_read_tokens: number;
  cache_write_5m_tokens: number;
  cache_write_1h_tokens: number;
  cache_write_inferred_tokens: number;
  output_tokens: number;
  reasoning_tokens: number;
  requests: number;
  context_bucket: ContextBucket;
  service_tier: string;
  speed: string;
  inference_geo: string;
  billable_tools: Readonly<Partial<Record<"web_search" | "web_fetch", number>>>;
  source_cost_microusd?: bigint;
  source_cost_covered_requests: number;
}

/** Aggregate validated request facts into deterministic sparse local-hour rows. */
export function aggregateUsageEvents(
  events: readonly NormalizedUsageEvent[],
  aggregationTimezone: string,
): UsageHourlyFact[] {
  const timezone = IanaTimezoneSchema.parse(aggregationTimezone);
  const dateParts = new Intl.DateTimeFormat("en-CA", {
    timeZone: timezone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    hourCycle: "h23",
  });
  const rows = new Map<string, MutableUsageFact>();

  for (const event of events) {
    const instant = Date.parse(Rfc3339InstantSchema.parse(event.occurred_at));
    const bucketStart = new Date(Math.floor(instant / 3_600_000) * 3_600_000)
      .toISOString()
      .replace(".000Z", "Z");
    const local = localDateAndHour(dateParts, new Date(instant));
    const fact = UsageHourlyFactSchema.parse({
      bucket_start_utc: bucketStart,
      usage_date: local.date,
      usage_hour: local.hour,
      agent: event.agent,
      billing_channel: event.billing_channel,
      channel_source: event.channel_source,
      model: event.model,
      context_bucket: event.context_bucket,
      service_tier: event.service_tier,
      speed: event.speed,
      inference_geo: event.inference_geo,
      input_tokens: event.input_tokens,
      cache_read_tokens: event.cache_read_tokens,
      cache_write_5m_tokens: event.cache_write_5m_tokens,
      cache_write_1h_tokens: event.cache_write_1h_tokens,
      cache_write_inferred_tokens: event.cache_write_inferred_tokens,
      output_tokens: event.output_tokens,
      reasoning_tokens: event.reasoning_tokens,
      requests: event.requests,
      web_search_requests: event.billable_tools.web_search ?? 0,
      web_fetch_requests: event.billable_tools.web_fetch ?? 0,
      ...(event.source_cost_microusd === undefined
        ? {}
        : { source_cost_microusd: event.source_cost_microusd.toString() }),
      source_cost_covered_requests: event.source_cost_covered_requests,
    });
    const key = JSON.stringify([
      fact.bucket_start_utc,
      fact.usage_date,
      fact.usage_hour,
      fact.agent,
      fact.billing_channel,
      fact.channel_source,
      fact.model,
      fact.context_bucket,
      fact.service_tier,
      fact.speed,
      fact.inference_geo,
    ]);
    const existing = rows.get(key);
    if (existing) {
      addFact(existing, fact);
    } else {
      rows.set(key, mutableFact(fact));
    }
  }

  return [...rows.values()]
    .sort(compareUsageFacts)
    .map((row) => UsageHourlyFactSchema.parse(serializedFact(row)));
}

/** Fold facts without losing token subsets or source-cost coverage. */
export function foldUsageFacts(rows: readonly UsageHourlyFact[]): UsageTokenTotals {
  const totals: MutableUsageTotals = {
    input_tokens: 0,
    cache_read_tokens: 0,
    cache_write_5m_tokens: 0,
    cache_write_1h_tokens: 0,
    cache_write_inferred_tokens: 0,
    output_tokens: 0,
    reasoning_tokens: 0,
    requests: 0,
    web_search_requests: 0,
    web_fetch_requests: 0,
    source_cost_microusd: 0n,
    source_cost_covered_requests: 0,
  };
  for (const input of rows) {
    const row = UsageHourlyFactSchema.parse(input);
    addCounts(totals, row);
  }
  return UsageTokenTotalsSchema.parse({
    ...totals,
    source_cost_microusd:
      totals.source_cost_covered_requests === 0 ? null : totals.source_cost_microusd.toString(),
  });
}

export type PricingCatalogValidationIssue =
  | { code: "invalid_schema"; path: string; message: string }
  | { code: "duplicate_entry_id"; entry_ids: readonly [string, string] }
  | { code: "ambiguous_entries"; entry_ids: readonly [string, string] };

export type PricingCatalogValidationResult =
  | { valid: true; catalog: PricingCatalog }
  | { valid: false; issues: readonly PricingCatalogValidationIssue[] };

/** Validate catalog structure and reject any pair that could resolve the same stored row. */
export function validatePricingCatalog(input: unknown): PricingCatalogValidationResult {
  const parsed = PricingCatalogSchema.safeParse(input);
  if (!parsed.success) {
    return {
      valid: false,
      issues: parsed.error.issues.map((issue) => ({
        code: "invalid_schema" as const,
        path: issue.path.join("."),
        message: issue.message,
      })),
    };
  }

  const issues: PricingCatalogValidationIssue[] = [];
  const ids = new Set<string>();
  for (const entry of parsed.data.entries) {
    if (ids.has(entry.entry_id)) {
      issues.push({
        code: "duplicate_entry_id",
        entry_ids: [entry.entry_id, entry.entry_id],
      });
    }
    ids.add(entry.entry_id);
  }
  for (let leftIndex = 0; leftIndex < parsed.data.entries.length; leftIndex += 1) {
    const left = parsed.data.entries[leftIndex];
    if (!left) continue;
    for (let rightIndex = leftIndex + 1; rightIndex < parsed.data.entries.length; rightIndex += 1) {
      const right = parsed.data.entries[rightIndex];
      if (right && pricingEntriesAreAmbiguous(left, right)) {
        issues.push({
          code: "ambiguous_entries",
          entry_ids: [left.entry_id, right.entry_id],
        });
      }
    }
  }
  return issues.length === 0 ? { valid: true, catalog: parsed.data } : { valid: false, issues };
}

export type ModelCatalogValidationIssue =
  | { code: "invalid_schema"; path: string; message: string }
  | { code: "duplicate_canonical_id"; canonical_id: string }
  | { code: "ambiguous_aliases"; reported_model: string; provider: InferenceProvider };

export type ModelCatalogValidationResult =
  | { valid: true; catalog: ModelCatalog }
  | { valid: false; issues: readonly ModelCatalogValidationIssue[] };

/** Validate model identity metadata and reject aliases that could resolve ambiguously. */
export function validateModelCatalog(input: unknown): ModelCatalogValidationResult {
  const parsed = ModelCatalogSchema.safeParse(input);
  if (!parsed.success) {
    return {
      valid: false,
      issues: parsed.error.issues.map((issue) => ({
        code: "invalid_schema" as const,
        path: issue.path.join("."),
        message: issue.message,
      })),
    };
  }

  const issues: ModelCatalogValidationIssue[] = [];
  const ids = new Set<string>();
  let aliasCount = 0;
  for (const model of parsed.data.models) {
    if (ids.has(model.canonical_id)) {
      issues.push({ code: "duplicate_canonical_id", canonical_id: model.canonical_id });
    }
    ids.add(model.canonical_id);
    aliasCount += model.aliases.length;
  }
  if (aliasCount > MAXIMUM_MODEL_CATALOG_ALIASES) {
    issues.push({
      code: "invalid_schema",
      path: "models",
      message: `A model catalog may contain at most ${MAXIMUM_MODEL_CATALOG_ALIASES} aliases.`,
    });
  }

  const aliases = parsed.data.models.flatMap((model) =>
    model.aliases.map((alias) => ({ model, alias })),
  );
  for (const { alias } of aliases) {
    if (ids.has(alias.reported_model)) {
      issues.push({
        code: "ambiguous_aliases",
        reported_model: alias.reported_model,
        provider: alias.provider,
      });
    }
  }
  for (let leftIndex = 0; leftIndex < aliases.length; leftIndex += 1) {
    const left = aliases[leftIndex];
    if (!left) continue;
    for (let rightIndex = leftIndex + 1; rightIndex < aliases.length; rightIndex += 1) {
      const right = aliases[rightIndex];
      if (right && aliasesOverlap(left.alias, right.alias)) {
        issues.push({
          code: "ambiguous_aliases",
          reported_model: left.alias.reported_model,
          provider: left.alias.provider,
        });
      }
    }
  }
  return issues.length === 0 ? { valid: true, catalog: parsed.data } : { valid: false, issues };
}

/** Resolve an exact canonical ID or explicitly scoped alias. */
export function resolveModel(
  catalog: ModelCatalog,
  row: Pick<UsageHourlyFact, "model" | "billing_channel" | "agent" | "bucket_start_utc">,
): string | undefined {
  const canonical = catalog.models.find((model) => model.canonical_id === row.model);
  if (canonical) return canonical.canonical_id;
  const date = row.bucket_start_utc.slice(0, 10);
  const provider = inferenceProvider(row.billing_channel);
  const matches = catalog.models.flatMap((model) =>
    model.aliases
      .filter(
        (alias) =>
          alias.reported_model === row.model &&
          alias.provider === provider &&
          (alias.agent === undefined || alias.agent === row.agent) &&
          (alias.effective_from === undefined || alias.effective_from <= date) &&
          (alias.effective_to === undefined || date < alias.effective_to),
      )
      .map(() => model),
  );
  return matches.length === 1 ? matches[0]?.canonical_id : undefined;
}

function aliasesOverlap(
  left: ModelCatalog["models"][number]["aliases"][number],
  right: ModelCatalog["models"][number]["aliases"][number],
): boolean {
  if (
    left.reported_model !== right.reported_model ||
    left.provider !== right.provider ||
    (left.agent !== undefined && right.agent !== undefined && left.agent !== right.agent)
  ) {
    return false;
  }
  const startsOverlap =
    left.effective_from === undefined ||
    right.effective_to === undefined ||
    left.effective_from < right.effective_to;
  const endsOverlap =
    right.effective_from === undefined ||
    left.effective_to === undefined ||
    right.effective_from < left.effective_to;
  return startsOverlap && endsOverlap;
}

export function inferenceProvider(channel: BillingChannel): InferenceProvider {
  switch (channel) {
    case "openai_direct":
      return "openai";
    case "anthropic_direct":
      return "anthropic";
    case "xai_direct":
      return "xai";
    case "moonshot_direct":
      return "moonshot";
    case "deepseek_direct":
      return "deepseek";
    default:
      return channel;
  }
}

export type PricingResolution =
  | {
      status: "priced";
      entry: PricingCatalogEntry;
      assumptions: readonly UsageCostAssumption[];
    }
  | { status: "unpriced"; reason: Exclude<UsageUnpricedReason, "invalid_catalog"> };

/** Resolve only an exact channel/model/date/dimension entry or an explicit catalog wildcard. */
export function resolvePricingEntry(
  catalog: PricingCatalog,
  row: UsageHourlyFact,
): PricingResolution {
  if (row.billing_channel === "unknown") {
    return { status: "unpriced", reason: "unknown_channel" };
  }
  const byChannel = catalog.entries.filter(
    (entry) => entry.billing_channel === row.billing_channel,
  );
  const byModel = byChannel.filter(
    (entry) => entry.model === row.model || entry.aliases.includes(row.model),
  );
  if (byModel.length === 0) {
    return { status: "unpriced", reason: "unknown_model" };
  }
  const pricingDate = row.bucket_start_utc.slice(0, 10);
  const byDate = byModel.filter(
    (entry) =>
      entry.effective_from <= pricingDate &&
      (entry.effective_to === null || pricingDate < entry.effective_to),
  );
  if (byDate.length === 0) {
    return { status: "unpriced", reason: "outside_effective_range" };
  }
  const matches = byDate
    .filter(
      (entry) =>
        dimensionMatches(entry.service_tier, row.service_tier) &&
        dimensionMatches(entry.speed, row.speed) &&
        dimensionMatches(entry.inference_geo, row.inference_geo) &&
        dimensionMatches(entry.context_bucket, row.context_bucket),
    )
    .map((entry) => ({ entry, specificity: pricingSpecificity(entry, row.model) }))
    .sort((left, right) => right.specificity - left.specificity);
  if (matches.length === 0) {
    return { status: "unpriced", reason: "unsupported_dimensions" };
  }
  const match = matches[0];
  if (!match || matches[1]?.specificity === match.specificity) {
    return { status: "unpriced", reason: "ambiguous_price" };
  }
  const entry = match.entry;
  const assumptions: UsageCostAssumption[] = [];
  if (entry.model !== row.model) assumptions.push("model_alias");
  if (entry.service_tier === "*") assumptions.push("wildcard_service_tier");
  if (entry.speed === "*") assumptions.push("wildcard_speed");
  if (entry.inference_geo === "*") assumptions.push("wildcard_inference_geo");
  if (entry.context_bucket === "*") assumptions.push("wildcard_context_bucket");
  return { status: "priced", entry, assumptions };
}

/** Calculate each stored row exactly, half-up once per row, then add integer micro-USD. */
export function calculateUsageCost(
  inputRows: readonly UsageHourlyFact[],
  catalogInput: unknown,
  mode: UsageCostMode = "calculate",
): UsageCostOutcome {
  return foldPreparedUsageCosts(prepareUsageCosts(inputRows, catalogInput, mode));
}

export type PreparedUsageCostRow =
  | {
      status: "priced";
      billing_channel: BillingChannel;
      model: string;
      amount_microusd: bigint;
      basis: "calculated" | "reported";
      assumptions: readonly UsageCostAssumption[];
    }
  | {
      status: "unpriced";
      billing_channel: BillingChannel;
      model: string;
      reason: UsageUnpricedReason;
    };

export interface PreparedUsageCosts {
  mode: UsageCostMode;
  catalog_revision: string | null;
  rows: readonly PreparedUsageCostRow[];
}

/**
 * Validating a catalog parses every entry and compares every pair, so a caller
 * that serves requests from one long-lived catalog object pays it once instead
 * of per request. Keyed by identity: a different object still revalidates.
 */
const validatedCatalogs = new WeakMap<object, PricingCatalogValidationResult>();

function validatePricingCatalogOnce(catalogInput: unknown): PricingCatalogValidationResult {
  if (typeof catalogInput !== "object" || catalogInput === null) {
    return validatePricingCatalog(catalogInput);
  }
  const cached = validatedCatalogs.get(catalogInput);
  if (cached) return cached;
  const validation = validatePricingCatalog(catalogInput);
  validatedCatalogs.set(catalogInput, validation);
  return validation;
}

/** Resolve and round every row once so callers can cheaply fold overlapping breakdown groups. */
export function prepareUsageCosts(
  inputRows: readonly UsageHourlyFact[],
  catalogInput: unknown,
  mode: UsageCostMode = "calculate",
): PreparedUsageCosts {
  const rows = inputRows.map((row) => UsageHourlyFactSchema.parse(row));
  const validation = mode === "reported" ? null : validatePricingCatalogOnce(catalogInput);
  const catalog = validation?.valid === true ? validation.catalog : null;
  const prepared = rows.map((row): PreparedUsageCostRow => {
    const calculated =
      mode === "reported"
        ? null
        : catalog === null
          ? ({ status: "unpriced", reason: "invalid_catalog" } as const)
          : calculateRowFromCatalog(catalog, row);
    if (calculated?.status === "priced") {
      return {
        status: "priced",
        billing_channel: row.billing_channel,
        model: row.model,
        amount_microusd: calculated.amount_microusd,
        basis: "calculated",
        assumptions:
          row.channel_source === "agent_default"
            ? [...calculated.assumptions, "agent_default_channel"]
            : calculated.assumptions,
      };
    }

    const canUseReported =
      (mode === "reported" || (mode === "auto" && calculated?.reason !== "invalid_catalog")) &&
      row.source_cost_microusd !== undefined &&
      row.source_cost_covered_requests === row.requests;
    if (canUseReported) {
      return {
        status: "priced",
        billing_channel: row.billing_channel,
        model: row.model,
        amount_microusd: BigInt(row.source_cost_microusd ?? "0"),
        basis: "reported",
        assumptions:
          row.channel_source === "agent_default"
            ? ["source_reported", "agent_default_channel"]
            : ["source_reported"],
      };
    }

    const reason: UsageUnpricedReason =
      mode === "reported" ? "incomplete_source_cost" : (calculated?.reason ?? "invalid_catalog");
    return {
      status: "unpriced",
      billing_channel: row.billing_channel,
      model: row.model,
      reason,
    };
  });
  return {
    mode,
    catalog_revision: catalog?.revision ?? null,
    rows: prepared,
  };
}

/** Fold all prepared rows, or a caller-selected set of row indexes, without re-resolving prices. */
export function foldPreparedUsageCosts(
  prepared: PreparedUsageCosts,
  indexes?: readonly number[],
): UsageCostOutcome {
  const assumptions = new Set<UsageCostAssumption>();
  const unpricedCounts = new Map<string, UsageUnpricedItem>();
  let amount = 0n;
  let calculatedRows = 0;
  let reportedRows = 0;

  const selectedRows = indexes?.length ?? prepared.rows.length;
  const selectedIndexes = indexes ?? prepared.rows.keys();
  for (const index of selectedIndexes) {
    const row = prepared.rows[index];
    if (!row) throw new RangeError(`Missing prepared Usage row at index ${index}.`);
    if (row.status === "priced") {
      amount += row.amount_microusd;
      if (row.basis === "calculated") calculatedRows += 1;
      else reportedRows += 1;
      for (const assumption of row.assumptions) assumptions.add(assumption);
      continue;
    }
    const key = `${row.billing_channel}\u0000${row.model}\u0000${row.reason}`;
    const existing = unpricedCounts.get(key);
    if (existing) existing.rows += 1;
    else {
      unpricedCounts.set(key, {
        billing_channel: row.billing_channel,
        model: row.model,
        reason: row.reason,
        rows: 1,
      });
    }
  }

  const unpriced = [...unpricedCounts.values()].sort(compareUnpricedItems);
  const unpricedRows = selectedRows - calculatedRows - reportedRows;
  return UsageCostOutcomeSchema.parse({
    mode: prepared.mode,
    basis:
      calculatedRows > 0 && reportedRows > 0
        ? "mixed"
        : calculatedRows > 0
          ? "calculated"
          : reportedRows > 0
            ? "reported"
            : "none",
    status:
      unpricedRows === 0
        ? "complete"
        : calculatedRows + reportedRows > 0
          ? "partial"
          : "unavailable",
    amount_microusd: calculatedRows + reportedRows > 0 ? amount.toString() : null,
    catalog_revision: prepared.catalog_revision,
    calculated_rows: calculatedRows,
    reported_rows: reportedRows,
    unpriced_rows: unpricedRows,
    assumptions: [...assumptions].sort(),
    unpriced,
  });
}

export type CalculatedUsageRowCost =
  | {
      status: "priced";
      amount_microusd: bigint;
      assumptions: readonly UsageCostAssumption[];
      entry_id: string;
    }
  | { status: "unpriced"; reason: UsageUnpricedReason };

export function calculateUsageRowCost(
  catalog: PricingCatalog,
  input: UsageHourlyFact,
): CalculatedUsageRowCost {
  return calculateRowFromCatalog(catalog, UsageHourlyFactSchema.parse(input));
}

interface MutableUsageTotals {
  input_tokens: number;
  cache_read_tokens: number;
  cache_write_5m_tokens: number;
  cache_write_1h_tokens: number;
  cache_write_inferred_tokens: number;
  output_tokens: number;
  reasoning_tokens: number;
  requests: number;
  web_search_requests: number;
  web_fetch_requests: number;
  source_cost_microusd: bigint;
  source_cost_covered_requests: number;
}

interface MutableUsageFact
  extends Omit<UsageHourlyFact, "source_cost_microusd">,
    MutableUsageTotals {}

function mutableFact(fact: UsageHourlyFact): MutableUsageFact {
  return {
    ...fact,
    source_cost_microusd: BigInt(fact.source_cost_microusd ?? "0"),
  };
}

function serializedFact(fact: MutableUsageFact): UsageHourlyFact {
  const { source_cost_microusd, ...rest } = fact;
  return {
    ...rest,
    ...(fact.source_cost_covered_requests === 0
      ? {}
      : { source_cost_microusd: source_cost_microusd.toString() }),
  };
}

const COUNT_KEYS = [
  "input_tokens",
  "cache_read_tokens",
  "cache_write_5m_tokens",
  "cache_write_1h_tokens",
  "cache_write_inferred_tokens",
  "output_tokens",
  "reasoning_tokens",
  "requests",
  "web_search_requests",
  "web_fetch_requests",
  "source_cost_covered_requests",
] as const;

function addFact(target: MutableUsageFact, source: UsageHourlyFact): void {
  addCounts(target, source);
  UsageHourlyFactSchema.parse(serializedFact(target));
}

function addCounts(target: MutableUsageTotals, source: UsageHourlyFact): void {
  for (const key of COUNT_KEYS) {
    target[key] = addSafeIntegers(target[key], source[key]);
  }
  target.source_cost_microusd += BigInt(source.source_cost_microusd ?? "0");
}

function addSafeIntegers(left: number, right: number): number {
  const result = left + right;
  if (!Number.isSafeInteger(result)) {
    throw new RangeError("Usage count exceeds the JSON safe-integer range.");
  }
  return result;
}

function localDateAndHour(
  formatter: Intl.DateTimeFormat,
  instant: Date,
): { date: string; hour: number } {
  const parts = Object.fromEntries(
    formatter
      .formatToParts(instant)
      .filter((part) => part.type !== "literal")
      .map((part) => [part.type, part.value]),
  );
  return {
    date: `${parts.year}-${parts.month}-${parts.day}`,
    hour: Number(parts.hour),
  };
}

function compareUsageFacts(left: MutableUsageFact, right: MutableUsageFact): number {
  return usageFactSortKey(left).localeCompare(usageFactSortKey(right));
}

function usageFactSortKey(fact: MutableUsageFact): string {
  return JSON.stringify([
    fact.bucket_start_utc,
    fact.usage_date,
    fact.usage_hour,
    fact.agent,
    fact.billing_channel,
    fact.channel_source,
    fact.model,
    fact.context_bucket,
    fact.service_tier,
    fact.speed,
    fact.inference_geo,
  ]);
}

function pricingEntriesAreAmbiguous(
  left: PricingCatalogEntry,
  right: PricingCatalogEntry,
): boolean {
  if (
    left.billing_channel !== right.billing_channel ||
    !rangesOverlap(
      left.effective_from,
      left.effective_to,
      right.effective_from,
      right.effective_to,
    ) ||
    !dimensionsOverlap(left.service_tier, right.service_tier) ||
    !dimensionsOverlap(left.speed, right.speed) ||
    !dimensionsOverlap(left.inference_geo, right.inference_geo) ||
    !dimensionsOverlap(left.context_bucket, right.context_bucket)
  ) {
    return false;
  }
  return modelNames(left).some(
    (model) =>
      modelNames(right).includes(model) &&
      pricingSpecificity(left, model) === pricingSpecificity(right, model),
  );
}

function modelNames(entry: PricingCatalogEntry): string[] {
  return [entry.model, ...entry.aliases];
}

function rangesOverlap(
  leftFrom: string,
  leftTo: string | null,
  rightFrom: string,
  rightTo: string | null,
): boolean {
  return (rightTo === null || leftFrom < rightTo) && (leftTo === null || rightFrom < leftTo);
}

function dimensionsOverlap(left: string, right: string): boolean {
  return left === "*" || right === "*" || left === right;
}

function dimensionMatches(expected: string, actual: string): boolean {
  return expected === "*" || expected === actual;
}

function pricingSpecificity(entry: PricingCatalogEntry, model: string): number {
  return (
    (entry.model === model ? 16 : 0) +
    [entry.service_tier, entry.speed, entry.inference_geo, entry.context_bucket].filter(
      (dimension) => dimension !== "*",
    ).length
  );
}

function calculateRowFromCatalog(
  catalog: PricingCatalog,
  row: UsageHourlyFact,
): CalculatedUsageRowCost {
  const resolution = resolvePricingEntry(catalog, row);
  if (resolution.status === "unpriced") return resolution;
  const classifiedInput =
    row.cache_read_tokens +
    row.cache_write_5m_tokens +
    row.cache_write_1h_tokens +
    row.cache_write_inferred_tokens;
  const components: Array<{ count: number; rate: string | null; perRequest?: true }> = [
    {
      count: row.input_tokens - classifiedInput,
      rate: resolution.entry.rates.uncached_input_per_million,
    },
    { count: row.cache_read_tokens, rate: resolution.entry.rates.cache_read_per_million },
    { count: row.cache_write_5m_tokens, rate: resolution.entry.rates.cache_write_5m_per_million },
    { count: row.cache_write_1h_tokens, rate: resolution.entry.rates.cache_write_1h_per_million },
    {
      count: row.cache_write_inferred_tokens,
      rate: resolution.entry.rates.cache_write_inferred_per_million,
    },
    { count: row.output_tokens, rate: resolution.entry.rates.output_per_million },
    {
      count: row.web_search_requests,
      rate: resolution.entry.rates.web_search_per_request,
      perRequest: true,
    },
    {
      count: row.web_fetch_requests,
      rate: resolution.entry.rates.web_fetch_per_request,
      perRequest: true,
    },
  ];
  if (components.some((component) => component.count > 0 && component.rate === null)) {
    return { status: "unpriced", reason: "missing_rate" };
  }
  const assumptions = [...resolution.assumptions];
  if (row.cache_write_inferred_tokens > 0) assumptions.push("cache_write_inferred_rate");
  return {
    status: "priced",
    amount_microusd: roundDecimalComponents(
      components
        .filter(
          (component): component is { count: number; rate: string; perRequest?: true } =>
            component.count > 0 && component.rate !== null,
        )
        .map((component) => ({
          count: BigInt(component.count) * (component.perRequest ? 1_000_000n : 1n),
          rate: component.rate,
        })),
    ),
    assumptions,
    entry_id: resolution.entry.entry_id,
  };
}

function roundDecimalComponents(components: readonly { count: bigint; rate: string }[]): bigint {
  const parsed = components.map((component) => ({
    count: component.count,
    ...parseDecimal(component.rate),
  }));
  const scale = parsed.reduce((maximum, component) => Math.max(maximum, component.scale), 0);
  const denominator = 10n ** BigInt(scale);
  const numerator = parsed.reduce(
    (sum, component) =>
      sum + component.count * component.numerator * 10n ** BigInt(scale - component.scale),
    0n,
  );
  return (numerator * 2n + denominator) / (denominator * 2n);
}

function parseDecimal(value: string): { numerator: bigint; scale: number } {
  const [integer = "0", fraction = ""] = value.split(".");
  return { numerator: BigInt(`${integer}${fraction}`), scale: fraction.length };
}

function compareUnpricedItems(left: UsageUnpricedItem, right: UsageUnpricedItem): number {
  return `${left.billing_channel}\u0000${left.model}\u0000${left.reason}`.localeCompare(
    `${right.billing_channel}\u0000${right.model}\u0000${right.reason}`,
  );
}

export type { PricingCatalog, PricingCatalogEntry, PricingRates, UsageHourlyFact };
export { PROTOCOL_VERSION };
