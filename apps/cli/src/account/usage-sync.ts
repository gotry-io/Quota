import { randomUUID } from "node:crypto";
import { aggregateUsageEvents } from "@gotry-io/quota-model";
import {
  type BillingAgent,
  BillingAgentSchema,
  IanaTimezoneSchema,
  MAXIMUM_USAGE_COVERAGE_HOURS,
  MAXIMUM_USAGE_SUBMISSION_BYTES,
  PROTOCOL_VERSION,
  Rfc3339InstantSchema,
  UsageSubmissionSchema,
  type UsageSubmissionV2,
  type UsageUploadResponse,
  UtcHourSchema,
} from "@gotry-io/quota-protocol";
import {
  type NormalizedUsageEvent,
  scanClaudeUsage,
  scanCodexUsage,
  type UsageScanResult,
} from "@gotry-io/quota-provider";
import { z } from "zod";
import { AccountClientError } from "./client.ts";
import {
  type AccountStateStore,
  AccountStateStoreError,
  type ActiveAccountSessionState,
} from "./state.ts";

const USAGE_STATE_SCHEMA_VERSION = 1 as const;
const USAGE_PARSER_REVISION = "quota-usage-2";
const USAGE_AGENTS = ["codex", "claude_code"] as const;
const MAX_CONTEXTS = 32;
const MAX_OUTBOX_ENTRIES = 64;
const MAX_UPLOADS_PER_SYNC = 8;

interface UsageCursor {
  agent: BillingAgent;
  next_start_at: string;
}

interface UsageCacheContext {
  account_id: string;
  device_id: string;
  generation: number;
  parser_revision: string;
  aggregation_timezone: string;
  event_not_before: string;
  cursors: UsageCursor[];
}

interface UsageCacheArtifact {
  schema_version: typeof USAGE_STATE_SCHEMA_VERSION;
  contexts: UsageCacheContext[];
}

interface UsageOutboxQueue {
  account_id: string;
  device_id: string;
  generation: number;
  entries: UsageSubmissionV2[];
}

interface UsageOutboxArtifact {
  schema_version: typeof USAGE_STATE_SCHEMA_VERSION;
  queues: UsageOutboxQueue[];
}

const UsageOpaqueIdSchema = z
  .string()
  .min(1)
  .max(128)
  .refine((value) => value.trim() === value);
const UsageCursorSchema = z
  .object({ agent: BillingAgentSchema, next_start_at: UtcHourSchema })
  .strict();
const UsageCacheContextSchema = z
  .object({
    account_id: UsageOpaqueIdSchema,
    device_id: UsageOpaqueIdSchema,
    generation: z.number().int().positive().safe(),
    parser_revision: UsageOpaqueIdSchema,
    aggregation_timezone: IanaTimezoneSchema,
    event_not_before: Rfc3339InstantSchema,
    cursors: z.array(UsageCursorSchema).length(USAGE_AGENTS.length),
  })
  .strict()
  .superRefine((value, context) => {
    if (new Set(value.cursors.map((cursor) => cursor.agent)).size !== USAGE_AGENTS.length) {
      context.addIssue({ code: "custom", message: "Usage cursors must contain each agent once." });
    }
  });
const UsageCacheArtifactSchema = z
  .object({
    schema_version: z.literal(USAGE_STATE_SCHEMA_VERSION),
    contexts: z.array(UsageCacheContextSchema).max(MAX_CONTEXTS),
  })
  .strict();
const UsageOutboxQueueSchema = z
  .object({
    account_id: UsageOpaqueIdSchema,
    device_id: UsageOpaqueIdSchema,
    generation: z.number().int().positive().safe(),
    entries: z.array(UsageSubmissionSchema).max(MAX_OUTBOX_ENTRIES),
  })
  .strict();
const UsageOutboxArtifactSchema = z
  .object({
    schema_version: z.literal(USAGE_STATE_SCHEMA_VERSION),
    queues: z.array(UsageOutboxQueueSchema).max(MAX_CONTEXTS),
  })
  .strict();

export interface UsageSyncClient {
  uploadUsage(token: string, submission: UsageSubmissionV2): Promise<UsageUploadResponse>;
}

export interface UsageSyncDependencies {
  client: UsageSyncClient;
  store: AccountStateStore;
  aggregationTimezone(): string;
  scan(agent: BillingAgent, startAt: string, endAt: string): Promise<UsageScanResult>;
}

export interface UsageSyncResult {
  uploaded: number;
  pending: number;
  coverage: Array<{
    agent: BillingAgent;
    start_at: string;
    end_at: string;
    status: "complete" | "partial";
  }>;
}

export async function syncUsage(
  session: ActiveAccountSessionState,
  now: Date,
  dependencies: UsageSyncDependencies,
): Promise<UsageSyncResult> {
  const completedHour = floorUtcHour(now.toISOString());
  const eventNotBefore = laterInstant(
    session.upload_not_before,
    session.usage_deleted_before ?? session.upload_not_before,
  );
  const coverageStart = floorUtcHour(eventNotBefore);
  if (Date.parse(completedHour) <= Date.parse(coverageStart)) {
    return { uploaded: 0, pending: 0, coverage: [] };
  }

  const timezone = dependencies.aggregationTimezone();
  let outbox = decodeOutbox(await dependencies.store.loadArtifact("usage-outbox.json"));
  outbox = pruneOutbox(outbox, session);
  await dependencies.store.saveArtifact("usage-outbox.json", outbox);

  let uploaded = 0;
  ({ outbox, session, uploaded } = await drainOutbox(
    outbox,
    session,
    dependencies,
    MAX_UPLOADS_PER_SYNC,
  ));
  if (pendingFor(outbox, session) > 0 || uploaded >= MAX_UPLOADS_PER_SYNC) {
    return { uploaded, pending: pendingFor(outbox, session), coverage: [] };
  }

  let cache = decodeCache(await dependencies.store.loadArtifact("usage-cache.json"));
  cache = pruneCache(cache, session);
  const context = currentContext(cache, session, timezone, eventNotBefore, coverageStart);
  const coverage: UsageSyncResult["coverage"] = [];
  const newEntries: UsageSubmissionV2[] = [];
  let nextSequence = session.next_usage_sequence;

  for (const agent of USAGE_AGENTS) {
    const cursor = context.cursors.find((value) => value.agent === agent);
    if (!cursor || Date.parse(cursor.next_start_at) >= Date.parse(completedHour)) continue;
    const uninitializedCursor = cursor.next_start_at === coverageStart;
    const scanEnd = uninitializedCursor
      ? completedHour
      : addHours(
          cursor.next_start_at,
          Math.min(MAXIMUM_USAGE_COVERAGE_HOURS, hoursBetween(cursor.next_start_at, completedHour)),
        );
    const scan = await dependencies.scan(agent, cursor.next_start_at, scanEnd);
    coverage.push({
      agent,
      start_at: scan.coverage.start_at,
      end_at: scan.coverage.end_at,
      status: scan.coverage.status,
    });
    if (scan.coverage.status !== "complete") continue;

    const eligibleEvents = scan.records
      .map((record) => record.event)
      .filter((event) => Date.parse(event.occurred_at) >= Date.parse(eventNotBefore));
    if (uninitializedCursor && eligibleEvents.length === 0) {
      cursor.next_start_at = scanEnd;
      continue;
    }
    const startAt = uninitializedCursor
      ? floorUtcHour(
          eligibleEvents.reduce((earliest, event) =>
            Date.parse(event.occurred_at) < Date.parse(earliest.occurred_at) ? event : earliest,
          ).occurred_at,
        )
      : cursor.next_start_at;
    const built = buildBoundedSubmission({
      agent,
      startAt,
      maximumEndAt: scanEnd,
      events: eligibleEvents,
      session,
      sequence: nextSequence,
      timezone,
    });
    newEntries.push(built);
    nextSequence += 1;
    cursor.next_start_at = built.coverage.end_at;
  }

  cache = replaceContext(cache, context);
  outbox = appendEntries(outbox, session, newEntries);
  // Persist immutable work before advancing the scan cursor. A crash between these writes may
  // rescan and replace the same range, but can never skip unsent facts.
  await dependencies.store.saveArtifact("usage-outbox.json", outbox);
  await dependencies.store.saveArtifact("usage-cache.json", cache);

  const remainingCapacity = MAX_UPLOADS_PER_SYNC - uploaded;
  const drained = await drainOutbox(outbox, session, dependencies, remainingCapacity);
  uploaded += drained.uploaded;
  return {
    uploaded,
    pending: pendingFor(drained.outbox, drained.session),
    coverage,
  };
}

function buildBoundedSubmission(input: {
  agent: BillingAgent;
  startAt: string;
  maximumEndAt: string;
  events: readonly NormalizedUsageEvent[];
  session: ActiveAccountSessionState;
  sequence: number;
  timezone: string;
}): UsageSubmissionV2 {
  let hours = Math.min(
    MAXIMUM_USAGE_COVERAGE_HOURS,
    hoursBetween(input.startAt, input.maximumEndAt),
  );
  while (hours >= 1) {
    const endAt = addHours(input.startAt, hours);
    const rows = aggregateUsageEvents(
      input.events.filter(
        (event) =>
          Date.parse(event.occurred_at) >= Date.parse(input.startAt) &&
          Date.parse(event.occurred_at) < Date.parse(endAt),
      ),
      input.timezone,
    );
    const candidate = {
      protocol_version: PROTOCOL_VERSION,
      submission_id: randomUUID(),
      device_id: input.session.device_id,
      generation: input.session.device_generation,
      sequence: input.sequence,
      parser_revision: USAGE_PARSER_REVISION,
      aggregation_timezone: input.timezone,
      coverage: { agent: input.agent, start_at: input.startAt, end_at: endAt, status: "complete" },
      rows,
    };
    const parsed = UsageSubmissionSchema.safeParse(candidate);
    if (
      parsed.success &&
      Buffer.byteLength(JSON.stringify(parsed.data), "utf8") <= MAXIMUM_USAGE_SUBMISSION_BYTES
    ) {
      return parsed.data;
    }
    hours = Math.floor(hours / 2);
  }
  throw new AccountStateStoreError(
    "invalid_state",
    "One hour of local Usage exceeds the bounded Quota upload format.",
  );
}

async function drainOutbox(
  input: UsageOutboxArtifact,
  initialSession: ActiveAccountSessionState,
  dependencies: UsageSyncDependencies,
  limit: number,
): Promise<{
  outbox: UsageOutboxArtifact;
  session: ActiveAccountSessionState;
  uploaded: number;
}> {
  const outbox = input;
  let session = initialSession;
  let uploaded = 0;
  while (uploaded < limit) {
    const queue = queueFor(outbox, session);
    const entry = queue?.entries[0];
    if (!queue || !entry) break;
    if (entry.sequence > session.next_usage_sequence) {
      throw new AccountStateStoreError(
        "invalid_state",
        "The local Usage outbox has a sequence gap.",
      );
    }
    const response = await dependencies.client.uploadUsage(session.device.access_token, entry);
    validateUsageResponse(session, entry, response);
    if (response.outcome === "stale_generation" || response.outcome === "deleted") {
      throw new AccountClientError(
        response.outcome,
        "The Quota device can no longer upload Usage.",
        {
          status: 409,
        },
      );
    }
    if (response.outcome === "sequence_conflict") {
      throw new AccountStateStoreError(
        "invalid_state",
        "The local Usage sequence conflicts with another installation.",
      );
    }
    if (response.outcome !== "accepted" && response.outcome !== "duplicate") {
      throw new AccountStateStoreError("invalid_state", "Quota rejected complete Usage coverage.");
    }
    if (
      session.next_usage_sequence !== response.next_sequence ||
      session.usage_sync_revision !== response.usage_sync_revision
    ) {
      session = await dependencies.store.updateActiveSession((current) => ({
        ...current,
        next_usage_sequence: response.next_sequence,
        usage_sync_revision: response.usage_sync_revision,
      }));
    }
    // Checkpoint the acknowledgement before removing its immutable request. If the outbox write
    // fails, the server can safely return duplicate when the same submission is retried.
    queue.entries.shift();
    await dependencies.store.saveArtifact("usage-outbox.json", outbox);
    uploaded += 1;
  }
  return { outbox, session, uploaded };
}

function validateUsageResponse(
  session: ActiveAccountSessionState,
  entry: UsageSubmissionV2,
  response: UsageUploadResponse,
): void {
  if (
    response.device_id !== session.device_id ||
    response.device_generation !== session.device_generation ||
    ((response.outcome === "accepted" || response.outcome === "duplicate") &&
      response.accepted_sequence !== entry.sequence)
  ) {
    throw new AccountStateStoreError("invalid_state", "The Quota Usage response was invalid.");
  }
}

function currentContext(
  cache: UsageCacheArtifact,
  session: ActiveAccountSessionState,
  timezone: string,
  eventNotBefore: string,
  coverageStart: string,
): UsageCacheContext {
  return (
    cache.contexts.find(
      (value) =>
        value.account_id === session.account_id &&
        value.device_id === session.device_id &&
        value.generation === session.device_generation &&
        value.parser_revision === USAGE_PARSER_REVISION &&
        value.aggregation_timezone === timezone &&
        value.event_not_before === eventNotBefore,
    ) ?? {
      account_id: session.account_id,
      device_id: session.device_id,
      generation: session.device_generation,
      parser_revision: USAGE_PARSER_REVISION,
      aggregation_timezone: timezone,
      event_not_before: eventNotBefore,
      cursors: USAGE_AGENTS.map((agent) => ({ agent, next_start_at: coverageStart })),
    }
  );
}

function pruneCache(
  cache: UsageCacheArtifact,
  session: ActiveAccountSessionState,
): UsageCacheArtifact {
  return {
    ...cache,
    contexts: cache.contexts.filter(
      (value) =>
        value.account_id !== session.account_id ||
        value.device_id !== session.device_id ||
        value.generation === session.device_generation,
    ),
  };
}

function replaceContext(cache: UsageCacheArtifact, context: UsageCacheContext): UsageCacheArtifact {
  const contexts = cache.contexts.filter(
    (value) =>
      value.account_id !== context.account_id ||
      value.device_id !== context.device_id ||
      value.generation !== context.generation,
  );
  contexts.push(context);
  if (contexts.length > MAX_CONTEXTS) contexts.splice(0, contexts.length - MAX_CONTEXTS);
  return { schema_version: USAGE_STATE_SCHEMA_VERSION, contexts };
}

function pruneOutbox(
  outbox: UsageOutboxArtifact,
  session: ActiveAccountSessionState,
): UsageOutboxArtifact {
  return {
    ...outbox,
    queues: outbox.queues.filter(
      (value) =>
        value.account_id !== session.account_id ||
        value.device_id !== session.device_id ||
        value.generation === session.device_generation,
    ),
  };
}

function appendEntries(
  outbox: UsageOutboxArtifact,
  session: ActiveAccountSessionState,
  entries: readonly UsageSubmissionV2[],
): UsageOutboxArtifact {
  if (entries.length === 0) return outbox;
  let queue = queueFor(outbox, session);
  if (!queue) {
    queue = {
      account_id: session.account_id,
      device_id: session.device_id,
      generation: session.device_generation,
      entries: [],
    };
    outbox.queues.push(queue);
  }
  if (queue.entries.length + entries.length > MAX_OUTBOX_ENTRIES) {
    throw new AccountStateStoreError("invalid_state", "The local Usage outbox is full.");
  }
  queue.entries.push(...entries);
  return outbox;
}

function queueFor(
  outbox: UsageOutboxArtifact,
  session: ActiveAccountSessionState,
): UsageOutboxQueue | undefined {
  return outbox.queues.find(
    (value) =>
      value.account_id === session.account_id &&
      value.device_id === session.device_id &&
      value.generation === session.device_generation,
  );
}

function pendingFor(outbox: UsageOutboxArtifact, session: ActiveAccountSessionState): number {
  return queueFor(outbox, session)?.entries.length ?? 0;
}

function decodeCache(value: unknown): UsageCacheArtifact {
  if (value === null) return { schema_version: USAGE_STATE_SCHEMA_VERSION, contexts: [] };
  rejectNewerUsageState(value);
  const parsed = UsageCacheArtifactSchema.safeParse(value);
  if (!parsed.success) throw invalidArtifact();
  return parsed.data;
}

function decodeOutbox(value: unknown): UsageOutboxArtifact {
  if (value === null) return { schema_version: USAGE_STATE_SCHEMA_VERSION, queues: [] };
  rejectNewerUsageState(value);
  const parsed = UsageOutboxArtifactSchema.safeParse(value);
  if (!parsed.success) throw invalidArtifact();
  return parsed.data;
}

function rejectNewerUsageState(value: unknown): void {
  if (
    typeof value === "object" &&
    value !== null &&
    "schema_version" in value &&
    typeof value.schema_version === "number" &&
    Number.isSafeInteger(value.schema_version) &&
    value.schema_version > USAGE_STATE_SCHEMA_VERSION
  ) {
    throw new AccountStateStoreError(
      "client_upgrade_required",
      "This Usage state was written by a newer QuotaCLI. Upgrade before continuing.",
    );
  }
}

function invalidArtifact(): AccountStateStoreError {
  return new AccountStateStoreError("invalid_state", "The local Usage state is invalid.");
}

function laterInstant(left: string, right: string): string {
  return Date.parse(left) >= Date.parse(right) ? left : right;
}

function floorUtcHour(value: string): string {
  const time = Date.parse(value);
  if (!Number.isFinite(time)) throw invalidArtifact();
  return new Date(Math.floor(time / 3_600_000) * 3_600_000).toISOString().replace(".000Z", "Z");
}

function addHours(value: string, hours: number): string {
  return new Date(Date.parse(value) + hours * 3_600_000).toISOString().replace(".000Z", "Z");
}

function hoursBetween(start: string, end: string): number {
  return Math.floor((Date.parse(end) - Date.parse(start)) / 3_600_000);
}

export function defaultUsageSyncDependencies(
  client: UsageSyncClient,
  store: AccountStateStore,
): UsageSyncDependencies {
  return {
    client,
    store,
    aggregationTimezone: () => Intl.DateTimeFormat().resolvedOptions().timeZone,
    scan: async (agent, startAt, endAt) =>
      agent === "codex"
        ? await scanCodexUsage({ startAt, endAt })
        : await scanClaudeUsage({ startAt, endAt }),
  };
}
