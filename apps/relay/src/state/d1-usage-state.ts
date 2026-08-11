import { MAXIMUM_USAGE_COVERAGE_ITEMS } from "@gotry-io/quota-protocol";
import type {
  DevicePrincipal,
  StoredUsageCoverage,
  StoredUsageHourlyFact,
  UsageHourlyFact,
  UsageQuery,
  UsageQueryResult,
  UsageState,
  UsageSubmission,
  UsageWriteResult,
} from "@gotry-io/relay-core";
import { canonicalRequestDigest } from "../security.ts";

interface DeviceUsageControlRow {
  generation: number;
  last_usage_sequence: number;
  usage_sync_revision: number;
  deleted_before: string | null;
}

interface UsageReceiptRow {
  request_digest: string;
  generation: number;
  sequence: number;
  usage_sync_revision: number;
  agent: string;
  start_at: string;
  end_at: string;
  write_mode: "merge_partial" | null;
  multipart_batch_id: string | null;
  multipart_part_index: number | null;
  multipart_part_count: number | null;
}

interface MultipartPartRow {
  device_id: string;
  batch_id: string;
  part_index: number;
  part_count: number;
  submission_id: string;
  generation: number;
  sequence: number;
  request_digest: string;
  write_mode: "merge_partial" | null;
  agent: string;
  start_at: string;
  end_at: string;
  parser_revision: string;
  aggregation_timezone: string;
  rows_json: string;
  accepted_at: string;
}

interface UsageRow extends Omit<StoredUsageHourlyFact, "source_cost_microusd"> {
  source_cost_microusd: string | null;
}

export class D1UsageState implements UsageState {
  constructor(private readonly database: D1Database) {}

  async recordUsage(
    principal: DevicePrincipal,
    submission: UsageSubmission,
    receivedAt: string,
  ): Promise<UsageWriteResult> {
    const requestDigest = await canonicalRequestDigest(submission);
    const receipt = await this.getReceipt(principal.device_id, submission.submission_id);
    if (receipt) {
      if (!receiptMatches(receipt, submission, requestDigest)) {
        return { outcome: "sequence_conflict" };
      }
      if (receipt.multipart_batch_id) {
        const finalized = await this.finalizeMultipart(
          principal,
          receipt.multipart_batch_id,
          receivedAt,
        );
        if (finalized === "conflict") return { outcome: "sequence_conflict" };
      }
      return {
        outcome: "duplicate",
        usage_sync_revision: receipt.usage_sync_revision,
        next_sequence: receipt.sequence + 1,
      };
    }
    // Released clients used partial coverage as a read-only marker. Only the
    // explicit additive write mode may merge rows into an existing range.
    if (submission.coverage.status === "partial" && submission.write_mode !== "merge_partial") {
      return { outcome: "partial" };
    }
    const device = await this.database
      .prepare(
        `SELECT generation, last_usage_sequence, usage_sync_revision, deleted_before
         FROM devices
         WHERE id = ?1 AND account_id = ?2 AND signed_out_at IS NULL AND deleted_at IS NULL`,
      )
      .bind(principal.device_id, principal.account_id)
      .first<DeviceUsageControlRow>();
    if (
      !device ||
      device.generation !== principal.generation ||
      submission.generation !== principal.generation
    ) {
      return { outcome: "stale_device" };
    }
    if (
      device.deleted_before &&
      Date.parse(submission.coverage.start_at) < floorUtcHour(device.deleted_before)
    ) {
      return { outcome: "deleted_range" };
    }
    if (submission.sequence !== device.last_usage_sequence + 1) {
      return { outcome: "sequence_conflict" };
    }

    const revision = device.usage_sync_revision + 1;
    if (submission.multipart) {
      const staged = await this.stageMultipart(
        principal,
        submission,
        requestDigest,
        receivedAt,
        revision,
      );
      if (!staged) return { outcome: "sequence_conflict" };
      const finalized = await this.finalizeMultipart(
        principal,
        submission.multipart.batch_id,
        receivedAt,
      );
      if (finalized === "conflict") return { outcome: "sequence_conflict" };
      return {
        outcome: "accepted",
        usage_sync_revision: revision,
        next_sequence: submission.sequence + 1,
      };
    }

    const statements = this.acceptedSubmissionStatements(
      principal,
      submission,
      requestDigest,
      receivedAt,
      revision,
    );
    try {
      const results = await this.database.batch(statements);
      const updated = results.at(-1)?.results[0] as { usage_sync_revision?: number } | undefined;
      if (updated?.usage_sync_revision === revision) {
        return {
          outcome: "accepted",
          usage_sync_revision: revision,
          next_sequence: submission.sequence + 1,
        };
      }
    } catch {
      const concurrent = await this.getReceipt(principal.device_id, submission.submission_id);
      if (concurrent && receiptMatches(concurrent, submission, requestDigest)) {
        return {
          outcome: "duplicate",
          usage_sync_revision: concurrent.usage_sync_revision,
          next_sequence: concurrent.sequence + 1,
        };
      }
      const conflicting = await this.database
        .prepare(
          `SELECT 1 AS found FROM usage_submissions
           WHERE device_id = ?1 AND generation = ?2 AND sequence = ?3`,
        )
        .bind(principal.device_id, submission.generation, submission.sequence)
        .first<{ found: number }>();
      if (conflicting) return { outcome: "sequence_conflict" };
      throw new Error("Usage persistence failed");
    }
    return { outcome: "sequence_conflict" };
  }

  async queryAccountUsage(accountId: string, query: UsageQuery): Promise<UsageQueryResult> {
    const parameters: (string | number)[] = [accountId];
    const conditions = ["devices.account_id = ?1", "devices.deleted_at IS NULL"];
    if (query.device_id) {
      parameters.push(query.device_id);
      conditions.push(`facts.device_id = ?${parameters.length}`);
    }
    if (query.agents && query.agents.length > 0) {
      const placeholders = query.agents.map((agent) => {
        parameters.push(agent);
        return `?${parameters.length}`;
      });
      conditions.push(`facts.agent IN (${placeholders.join(", ")})`);
    }
    if (query.start_at) {
      parameters.push(query.start_at);
      conditions.push(`facts.bucket_start_utc >= ?${parameters.length}`);
    }
    if (query.end_at) {
      parameters.push(query.end_at);
      conditions.push(`facts.bucket_start_utc < ?${parameters.length}`);
    }
    if (query.from) {
      parameters.push(query.from);
      conditions.push(`facts.usage_date >= ?${parameters.length}`);
    }
    if (query.to) {
      parameters.push(query.to);
      conditions.push(`facts.usage_date <= ?${parameters.length}`);
    }
    parameters.push(query.limit + 1);
    const rows = await this.database
      .prepare(
        `SELECT facts.device_id, facts.bucket_start_utc, facts.usage_date, facts.usage_hour,
                facts.aggregation_timezone, facts.agent, facts.billing_channel,
                facts.channel_source, facts.model, facts.context_bucket, facts.service_tier,
                facts.speed, facts.inference_geo, facts.input_tokens, facts.cache_read_tokens,
                facts.cache_write_5m_tokens, facts.cache_write_1h_tokens,
                facts.cache_write_inferred_tokens, facts.output_tokens, facts.reasoning_tokens,
                facts.requests, facts.web_search_requests, facts.web_fetch_requests,
                facts.source_cost_microusd, facts.source_cost_covered_requests
         FROM usage_hourly AS facts
         INNER JOIN devices ON devices.id = facts.device_id
         WHERE ${conditions.join(" AND ")}
         ORDER BY facts.bucket_start_utc ASC, facts.device_id ASC, facts.usage_date ASC,
                  facts.usage_hour ASC, facts.agent ASC, facts.billing_channel ASC,
                  facts.channel_source ASC, facts.model ASC, facts.context_bucket ASC,
                  facts.service_tier ASC, facts.speed ASC, facts.inference_geo ASC
         LIMIT ?${parameters.length}`,
      )
      .bind(...parameters)
      .all<UsageRow>();

    const coverageParameters: (string | number)[] = [accountId];
    const coverageConditions = ["devices.account_id = ?1", "devices.deleted_at IS NULL"];
    if (query.device_id) {
      coverageParameters.push(query.device_id);
      coverageConditions.push(`coverage.device_id = ?${coverageParameters.length}`);
    }
    if (query.agents && query.agents.length > 0) {
      const placeholders = query.agents.map((agent) => {
        coverageParameters.push(agent);
        return `?${coverageParameters.length}`;
      });
      coverageConditions.push(`coverage.agent IN (${placeholders.join(", ")})`);
    }
    if (query.start_at) {
      coverageParameters.push(query.start_at);
      coverageConditions.push(`coverage.end_at > ?${coverageParameters.length}`);
    }
    if (query.end_at) {
      coverageParameters.push(query.end_at);
      coverageConditions.push(`coverage.start_at < ?${coverageParameters.length}`);
    }
    const coverageLimit = Math.min(query.limit, MAXIMUM_USAGE_COVERAGE_ITEMS);
    coverageParameters.push(coverageLimit + 1);
    const coverage = await this.database
      .prepare(
        `SELECT coverage.device_id, coverage.agent, coverage.start_at, coverage.end_at,
                coverage.status,
                coverage.parser_revision, coverage.accepted_at
         FROM usage_coverage AS coverage
         INNER JOIN devices ON devices.id = coverage.device_id
         WHERE ${coverageConditions.join(" AND ")}
         ORDER BY coverage.start_at ASC, coverage.end_at ASC,
                  coverage.device_id ASC, coverage.agent ASC
         LIMIT ?${coverageParameters.length}`,
      )
      .bind(...coverageParameters)
      .all<StoredUsageCoverage>();

    const coverageTruncated = coverage.results.length > coverageLimit;
    return {
      rows: rows.results.slice(0, query.limit).map(({ source_cost_microusd, ...row }) => ({
        ...row,
        ...(source_cost_microusd === null ? {} : { source_cost_microusd }),
      })),
      coverage: coverage.results.slice(0, coverageLimit),
      truncated: rows.results.length > query.limit,
      coverage_truncated: coverageTruncated,
    };
  }

  private acceptedSubmissionStatements(
    principal: DevicePrincipal,
    submission: UsageSubmission,
    requestDigest: string,
    receivedAt: string,
    revision: number,
  ): D1PreparedStatement[] {
    const statements: D1PreparedStatement[] = [
      this.database
        .prepare(
          `INSERT INTO usage_submissions (
             device_id, submission_id, generation, sequence, request_digest,
             usage_sync_revision, agent, start_at, end_at, accepted_at,
             write_mode
           )
           SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11
           WHERE EXISTS (
             SELECT 1 FROM devices
             WHERE id = ?1 AND account_id = ?12 AND generation = ?3
               AND signed_out_at IS NULL AND deleted_at IS NULL
               AND last_usage_sequence = ?4 - 1
               AND (deleted_before IS NULL OR
                    strftime('%Y-%m-%dT%H:00:00.000Z', deleted_before) <= ?8)
           )`,
        )
        .bind(
          principal.device_id,
          submission.submission_id,
          submission.generation,
          submission.sequence,
          requestDigest,
          revision,
          submission.coverage.agent,
          submission.coverage.start_at,
          submission.coverage.end_at,
          receivedAt,
          submission.write_mode ?? null,
          principal.account_id,
        ),
    ];
    statements.push(
      ...this.usageMutationStatements(principal.device_id, submission, submission.rows, receivedAt),
    );

    statements.push(
      this.database
        .prepare(
          `UPDATE devices
           SET last_usage_sequence = ?3, usage_sync_revision = ?4, last_seen_at = ?5
           WHERE id = ?1 AND account_id = ?2 AND generation = ?6
             AND last_usage_sequence = ?3 - 1
             AND EXISTS (
               SELECT 1 FROM usage_submissions
               WHERE device_id = ?1 AND submission_id = ?7
             )
           RETURNING usage_sync_revision`,
        )
        .bind(
          principal.device_id,
          principal.account_id,
          submission.sequence,
          revision,
          receivedAt,
          submission.generation,
          submission.submission_id,
        ),
    );
    return statements;
  }

  private async stageMultipart(
    principal: DevicePrincipal,
    submission: UsageSubmission,
    requestDigest: string,
    receivedAt: string,
    revision: number,
  ): Promise<boolean> {
    const part = submission.multipart;
    if (!part) return false;
    const existing = await this.database
      .prepare(
        `SELECT part_count, agent, start_at, end_at, parser_revision,
                aggregation_timezone, write_mode
         FROM usage_submission_parts
         WHERE device_id = ?1 AND batch_id = ?2
         LIMIT 1`,
      )
      .bind(principal.device_id, part.batch_id)
      .first<
        Pick<
          MultipartPartRow,
          | "part_count"
          | "agent"
          | "start_at"
          | "end_at"
          | "parser_revision"
          | "aggregation_timezone"
          | "write_mode"
        >
      >();
    if (
      existing &&
      (existing.part_count !== part.part_count ||
        existing.agent !== submission.coverage.agent ||
        existing.start_at !== submission.coverage.start_at ||
        existing.end_at !== submission.coverage.end_at ||
        existing.parser_revision !== submission.parser_revision ||
        existing.aggregation_timezone !== submission.aggregation_timezone ||
        existing.write_mode !== (submission.write_mode ?? null))
    ) {
      return false;
    }

    const statements = [
      this.database
        .prepare(
          `INSERT INTO usage_submissions (
             device_id, submission_id, generation, sequence, request_digest,
             usage_sync_revision, agent, start_at, end_at, accepted_at,
             write_mode, multipart_batch_id, multipart_part_index, multipart_part_count
           )
           SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14
           WHERE EXISTS (
             SELECT 1 FROM devices
             WHERE id = ?1 AND account_id = ?15 AND generation = ?3
               AND signed_out_at IS NULL AND deleted_at IS NULL
               AND last_usage_sequence = ?4 - 1
               AND (deleted_before IS NULL OR
                    strftime('%Y-%m-%dT%H:00:00.000Z', deleted_before) <= ?8)
           )`,
        )
        .bind(
          principal.device_id,
          submission.submission_id,
          submission.generation,
          submission.sequence,
          requestDigest,
          revision,
          submission.coverage.agent,
          submission.coverage.start_at,
          submission.coverage.end_at,
          receivedAt,
          submission.write_mode ?? null,
          part.batch_id,
          part.part_index,
          part.part_count,
          principal.account_id,
        ),
      this.database
        .prepare(
          `INSERT INTO usage_submission_parts (
             device_id, batch_id, part_index, part_count, submission_id,
             generation, sequence, request_digest, write_mode, agent,
             start_at, end_at, parser_revision, aggregation_timezone,
             rows_json, accepted_at
           )
           SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,
                  ?13, ?14, ?15, ?16
           WHERE EXISTS (
             SELECT 1 FROM usage_submissions
             WHERE device_id = ?1 AND submission_id = ?5
           )`,
        )
        .bind(
          principal.device_id,
          part.batch_id,
          part.part_index,
          part.part_count,
          submission.submission_id,
          submission.generation,
          submission.sequence,
          requestDigest,
          submission.write_mode ?? null,
          submission.coverage.agent,
          submission.coverage.start_at,
          submission.coverage.end_at,
          submission.parser_revision,
          submission.aggregation_timezone,
          JSON.stringify(submission.rows),
          receivedAt,
        ),
      this.database
        .prepare(
          `UPDATE devices
           SET last_usage_sequence = ?3, usage_sync_revision = ?4, last_seen_at = ?5
           WHERE id = ?1 AND account_id = ?2 AND generation = ?6
             AND last_usage_sequence = ?3 - 1
             AND EXISTS (
               SELECT 1 FROM usage_submissions
               WHERE device_id = ?1 AND submission_id = ?7
             )
           RETURNING usage_sync_revision`,
        )
        .bind(
          principal.device_id,
          principal.account_id,
          submission.sequence,
          revision,
          receivedAt,
          submission.generation,
          submission.submission_id,
        ),
    ];
    try {
      const results = await this.database.batch(statements);
      return (
        (results.at(-1)?.results[0] as { usage_sync_revision?: number } | undefined)
          ?.usage_sync_revision === revision
      );
    } catch {
      const concurrent = await this.getReceipt(principal.device_id, submission.submission_id);
      if (concurrent && receiptMatches(concurrent, submission, requestDigest)) return true;
      return false;
    }
  }

  private async finalizeMultipart(
    principal: DevicePrincipal,
    batchId: string,
    receivedAt: string,
  ): Promise<"pending" | "committed" | "conflict"> {
    const parts = await this.database
      .prepare(
        `SELECT device_id, batch_id, part_index, part_count, submission_id,
                generation, sequence, request_digest, write_mode, agent,
                start_at, end_at, parser_revision, aggregation_timezone,
                rows_json, accepted_at
         FROM usage_submission_parts
         WHERE device_id = ?1 AND batch_id = ?2
         ORDER BY part_index ASC`,
      )
      .bind(principal.device_id, batchId)
      .all<MultipartPartRow>();
    const first = parts.results[0];
    if (!first || parts.results.length !== first.part_count) return "pending";
    for (const [index, part] of parts.results.entries()) {
      if (
        part.part_index !== index ||
        part.part_count !== first.part_count ||
        part.agent !== first.agent ||
        part.start_at !== first.start_at ||
        part.end_at !== first.end_at ||
        part.parser_revision !== first.parser_revision ||
        part.aggregation_timezone !== first.aggregation_timezone ||
        part.write_mode !== first.write_mode
      ) {
        throw new Error("Multipart Usage metadata mismatch");
      }
    }

    // Check fact identities in SQL before any mutation. Complete batches would
    // fail on the Usage PK, while partial batches use an upsert and could
    // otherwise silently choose whichever duplicate happened to be last.
    // Keep the staged parts intact on conflict so the caller can diagnose or
    // retry the batch after fixing it; do not materialize all rows in Worker.
    const duplicate = await this.database
      .prepare(
        `SELECT 1 AS duplicate
         FROM usage_submission_parts AS part, json_each(part.rows_json) AS item
         WHERE part.device_id = ?1 AND part.batch_id = ?2
         GROUP BY
           json_extract(item.value, '$.bucket_start_utc'),
           json_extract(item.value, '$.usage_date'),
           json_extract(item.value, '$.usage_hour'),
           json_extract(item.value, '$.agent'),
           json_extract(item.value, '$.billing_channel'),
           json_extract(item.value, '$.channel_source'),
           json_extract(item.value, '$.model'),
           json_extract(item.value, '$.context_bucket'),
           json_extract(item.value, '$.service_tier'),
           json_extract(item.value, '$.speed'),
           json_extract(item.value, '$.inference_geo')
         HAVING COUNT(*) > 1
         LIMIT 1`,
      )
      .bind(principal.device_id, batchId)
      .first<{ duplicate: number }>();
    if (duplicate) return "conflict";

    const finalPart = parts.results.at(-1);
    if (!finalPart) return "pending";
    const submission: UsageSubmission = {
      protocol_version: 2,
      submission_id: finalPart.submission_id,
      device_id: finalPart.device_id,
      generation: finalPart.generation,
      sequence: finalPart.sequence,
      parser_revision: finalPart.parser_revision,
      aggregation_timezone: finalPart.aggregation_timezone,
      coverage: {
        agent: finalPart.agent as UsageSubmission["coverage"]["agent"],
        start_at: finalPart.start_at,
        end_at: finalPart.end_at,
        status: finalPart.write_mode === "merge_partial" ? "partial" : "complete",
      },
      // Rows remain private JSON staging data until the atomic JSON1 INSERT.
      // Do not materialize the whole multipart batch in Worker memory here.
      rows: [],
      ...(finalPart.write_mode ? { write_mode: finalPart.write_mode } : {}),
      multipart: {
        batch_id: finalPart.batch_id,
        part_index: finalPart.part_index,
        part_count: finalPart.part_count,
      },
    };
    const statements = this.usageMutationStatements(
      principal.device_id,
      submission,
      [],
      receivedAt,
      batchId,
    );
    statements.push(
      this.database
        .prepare("DELETE FROM usage_submission_parts WHERE device_id = ?1 AND batch_id = ?2")
        .bind(principal.device_id, batchId),
    );
    try {
      await this.database.batch(statements);
    } catch (error) {
      // A multipart batch must not silently merge duplicate fact identities.
      // D1 rolls the batch back, leaving every staged part and receipt
      // available for diagnosis/retry. Other failures must remain visible
      // instead of being converted into a generic conflict.
      if (isUsageFactConflict(error)) return "conflict";
      throw error;
    }
    return "committed";
  }

  private usageMutationStatements(
    deviceId: string,
    submission: UsageSubmission,
    rows: readonly UsageHourlyFact[],
    receivedAt: string,
    stagedBatchId?: string,
  ): D1PreparedStatement[] {
    const partial = submission.write_mode === "merge_partial";
    const statements: D1PreparedStatement[] = [];
    if (!partial) {
      statements.push(
        this.database
          .prepare(
            `DELETE FROM usage_hourly
             WHERE device_id = ?1 AND agent = ?2
               AND bucket_start_utc >= ?3 AND bucket_start_utc < ?4
               AND EXISTS (
                 SELECT 1 FROM usage_submissions
                 WHERE device_id = ?1 AND submission_id = ?5
               )`,
          )
          .bind(
            deviceId,
            submission.coverage.agent,
            submission.coverage.start_at,
            submission.coverage.end_at,
            submission.submission_id,
          ),
      );
    }
    if (stagedBatchId) {
      statements.push(this.insertStagedRows(deviceId, submission, stagedBatchId, partial));
    } else {
      statements.push(...rows.map((row) => this.insertRow(deviceId, submission, row, partial)));
    }
    if (partial) {
      statements.push(
        this.preserveCoverageSide(deviceId, submission, "left"),
        this.preserveCoverageSide(deviceId, submission, "right"),
        this.deleteCoverageOverlap(deviceId, submission),
        this.insertPartialCoverage(deviceId, submission, receivedAt),
      );
    } else {
      statements.push(
        this.preserveCoverageSide(deviceId, submission, "left"),
        this.preserveCoverageSide(deviceId, submission, "right"),
        this.deleteCoverageOverlap(deviceId, submission),
        this.insertCompleteCoverage(deviceId, submission, receivedAt),
      );
    }
    return statements;
  }

  private insertStagedRows(
    deviceId: string,
    submission: UsageSubmission,
    batchId: string,
    partial: boolean,
  ): D1PreparedStatement {
    const conflict = partial
      ? `
         ON CONFLICT (
           device_id, bucket_start_utc, usage_date, usage_hour,
           agent, billing_channel, channel_source, model,
           context_bucket, service_tier, speed, inference_geo
         ) DO UPDATE SET
           aggregation_timezone = excluded.aggregation_timezone,
           input_tokens = excluded.input_tokens,
           cache_read_tokens = excluded.cache_read_tokens,
           cache_write_5m_tokens = excluded.cache_write_5m_tokens,
           cache_write_1h_tokens = excluded.cache_write_1h_tokens,
           cache_write_inferred_tokens = excluded.cache_write_inferred_tokens,
           output_tokens = excluded.output_tokens,
           reasoning_tokens = excluded.reasoning_tokens,
           requests = excluded.requests,
           web_search_requests = excluded.web_search_requests,
           web_fetch_requests = excluded.web_fetch_requests,
           source_cost_microusd = excluded.source_cost_microusd,
           source_cost_covered_requests = excluded.source_cost_covered_requests`
      : "";
    return this.database
      .prepare(
        `INSERT INTO usage_hourly (
           device_id, bucket_start_utc, usage_date, usage_hour, aggregation_timezone, agent,
           billing_channel, channel_source, model, context_bucket, service_tier, speed,
           inference_geo, input_tokens, cache_read_tokens, cache_write_5m_tokens,
           cache_write_1h_tokens, cache_write_inferred_tokens, output_tokens, reasoning_tokens,
           requests, web_search_requests, web_fetch_requests, source_cost_microusd,
           source_cost_covered_requests
         )
         SELECT ?1,
                json_extract(item.value, '$.bucket_start_utc'),
                json_extract(item.value, '$.usage_date'),
                json_extract(item.value, '$.usage_hour'),
                ?2,
                json_extract(item.value, '$.agent'),
                json_extract(item.value, '$.billing_channel'),
                json_extract(item.value, '$.channel_source'),
                json_extract(item.value, '$.model'),
                json_extract(item.value, '$.context_bucket'),
                json_extract(item.value, '$.service_tier'),
                json_extract(item.value, '$.speed'),
                json_extract(item.value, '$.inference_geo'),
                json_extract(item.value, '$.input_tokens'),
                json_extract(item.value, '$.cache_read_tokens'),
                json_extract(item.value, '$.cache_write_5m_tokens'),
                json_extract(item.value, '$.cache_write_1h_tokens'),
                json_extract(item.value, '$.cache_write_inferred_tokens'),
                json_extract(item.value, '$.output_tokens'),
                json_extract(item.value, '$.reasoning_tokens'),
                json_extract(item.value, '$.requests'),
                json_extract(item.value, '$.web_search_requests'),
                json_extract(item.value, '$.web_fetch_requests'),
                json_extract(item.value, '$.source_cost_microusd'),
                json_extract(item.value, '$.source_cost_covered_requests')
         FROM usage_submission_parts AS part, json_each(part.rows_json) AS item
         WHERE part.device_id = ?1 AND part.batch_id = ?3${conflict}`,
      )
      .bind(deviceId, submission.aggregation_timezone, batchId);
  }

  private insertRow(
    deviceId: string,
    submission: UsageSubmission,
    row: UsageHourlyFact,
    partial = false,
  ): D1PreparedStatement {
    const conflict = partial
      ? `
         ON CONFLICT (
           device_id, bucket_start_utc, usage_date, usage_hour,
           agent, billing_channel, channel_source, model,
           context_bucket, service_tier, speed, inference_geo
         ) DO UPDATE SET
           aggregation_timezone = excluded.aggregation_timezone,
           input_tokens = excluded.input_tokens,
           cache_read_tokens = excluded.cache_read_tokens,
           cache_write_5m_tokens = excluded.cache_write_5m_tokens,
           cache_write_1h_tokens = excluded.cache_write_1h_tokens,
           cache_write_inferred_tokens = excluded.cache_write_inferred_tokens,
           output_tokens = excluded.output_tokens,
           reasoning_tokens = excluded.reasoning_tokens,
           requests = excluded.requests,
           web_search_requests = excluded.web_search_requests,
           web_fetch_requests = excluded.web_fetch_requests,
           source_cost_microusd = excluded.source_cost_microusd,
           source_cost_covered_requests = excluded.source_cost_covered_requests`
      : "";
    return this.database
      .prepare(
        `INSERT INTO usage_hourly (
           device_id, bucket_start_utc, usage_date, usage_hour, aggregation_timezone, agent,
           billing_channel, channel_source, model, context_bucket, service_tier, speed,
           inference_geo, input_tokens, cache_read_tokens, cache_write_5m_tokens,
           cache_write_1h_tokens, cache_write_inferred_tokens, output_tokens, reasoning_tokens,
           requests, web_search_requests, web_fetch_requests, source_cost_microusd,
           source_cost_covered_requests
         )
         SELECT ?1, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16,
                ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25, ?26
         WHERE EXISTS (
           SELECT 1 FROM usage_submissions
           WHERE device_id = ?1 AND submission_id = ?2
         )${conflict}`,
      )
      .bind(
        deviceId,
        submission.submission_id,
        row.bucket_start_utc,
        row.usage_date,
        row.usage_hour,
        submission.aggregation_timezone,
        row.agent,
        row.billing_channel,
        row.channel_source,
        row.model,
        row.context_bucket,
        row.service_tier,
        row.speed,
        row.inference_geo,
        row.input_tokens,
        row.cache_read_tokens,
        row.cache_write_5m_tokens,
        row.cache_write_1h_tokens,
        row.cache_write_inferred_tokens,
        row.output_tokens,
        row.reasoning_tokens,
        row.requests,
        row.web_search_requests,
        row.web_fetch_requests,
        row.source_cost_microusd ?? null,
        row.source_cost_covered_requests,
      );
  }

  private preserveCoverageSide(
    deviceId: string,
    submission: UsageSubmission,
    side: "left" | "right",
  ): D1PreparedStatement {
    const start = side === "left" ? "coverage.start_at" : "?5";
    const end = side === "left" ? "?4" : "coverage.end_at";
    const retained = side === "left" ? "coverage.start_at < ?4" : "coverage.end_at > ?5";
    return this.database
      .prepare(
        `INSERT INTO usage_coverage (
           device_id, agent, start_at, end_at, status, parser_revision, submission_id, accepted_at
         )
         SELECT coverage.device_id, coverage.agent, ${start}, ${end},
                coverage.status, coverage.parser_revision, coverage.submission_id, coverage.accepted_at
         FROM usage_coverage AS coverage
         WHERE coverage.device_id = ?1 AND coverage.agent = ?3
           AND coverage.start_at < ?5 AND coverage.end_at > ?4 AND ${retained}
           AND EXISTS (
             SELECT 1 FROM usage_submissions
             WHERE device_id = ?1 AND submission_id = ?2
           )
         ON CONFLICT(device_id, agent, start_at, end_at) DO NOTHING`,
      )
      .bind(
        deviceId,
        submission.submission_id,
        submission.coverage.agent,
        submission.coverage.start_at,
        submission.coverage.end_at,
      );
  }

  private insertPartialCoverage(
    deviceId: string,
    submission: UsageSubmission,
    acceptedAt: string,
  ): D1PreparedStatement {
    return this.database
      .prepare(
        `INSERT INTO usage_coverage (
           device_id, agent, start_at, end_at, status, parser_revision, submission_id, accepted_at
         )
         SELECT ?1, ?2, ?3, ?4, 'partial', ?5, ?6, ?7
         WHERE EXISTS (
           SELECT 1 FROM usage_submissions
           WHERE device_id = ?1 AND submission_id = ?6
         )`,
      )
      .bind(
        deviceId,
        submission.coverage.agent,
        submission.coverage.start_at,
        submission.coverage.end_at,
        submission.parser_revision,
        submission.submission_id,
        acceptedAt,
      );
  }

  private deleteCoverageOverlap(
    deviceId: string,
    submission: UsageSubmission,
  ): D1PreparedStatement {
    return this.database
      .prepare(
        `DELETE FROM usage_coverage
         WHERE device_id = ?1 AND agent = ?3 AND start_at < ?5 AND end_at > ?4
           AND EXISTS (
             SELECT 1 FROM usage_submissions
             WHERE device_id = ?1 AND submission_id = ?2
           )`,
      )
      .bind(
        deviceId,
        submission.submission_id,
        submission.coverage.agent,
        submission.coverage.start_at,
        submission.coverage.end_at,
      );
  }

  private insertCompleteCoverage(
    deviceId: string,
    submission: UsageSubmission,
    acceptedAt: string,
  ): D1PreparedStatement {
    return this.database
      .prepare(
        `INSERT INTO usage_coverage (
           device_id, agent, start_at, end_at, status, parser_revision, submission_id, accepted_at
         )
         SELECT ?1, ?3, ?4, ?5, 'complete', ?6, ?2, ?7
         WHERE EXISTS (
           SELECT 1 FROM usage_submissions
           WHERE device_id = ?1 AND submission_id = ?2
         )`,
      )
      .bind(
        deviceId,
        submission.submission_id,
        submission.coverage.agent,
        submission.coverage.start_at,
        submission.coverage.end_at,
        submission.parser_revision,
        acceptedAt,
      );
  }

  private async getReceipt(
    deviceId: string,
    submissionId: string,
  ): Promise<UsageReceiptRow | null> {
    return this.database
      .prepare(
        `SELECT request_digest, generation, sequence, usage_sync_revision, agent, start_at, end_at,
                write_mode, multipart_batch_id, multipart_part_index, multipart_part_count
         FROM usage_submissions WHERE device_id = ?1 AND submission_id = ?2`,
      )
      .bind(deviceId, submissionId)
      .first<UsageReceiptRow>();
  }
}

function receiptMatches(
  receipt: UsageReceiptRow,
  submission: UsageSubmission,
  requestDigest: string,
): boolean {
  return (
    receipt.request_digest === requestDigest &&
    receipt.generation === submission.generation &&
    receipt.sequence === submission.sequence &&
    receipt.agent === submission.coverage.agent &&
    receipt.start_at === submission.coverage.start_at &&
    receipt.end_at === submission.coverage.end_at &&
    receipt.write_mode === (submission.write_mode ?? null) &&
    receipt.multipart_batch_id === (submission.multipart?.batch_id ?? null) &&
    receipt.multipart_part_index === (submission.multipart?.part_index ?? null) &&
    receipt.multipart_part_count === (submission.multipart?.part_count ?? null)
  );
}

function isUsageFactConflict(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return message.includes("UNIQUE constraint failed: usage_hourly.");
}

function floorUtcHour(value: string): number {
  const instant = Date.parse(value);
  return instant - (instant % 3_600_000);
}
