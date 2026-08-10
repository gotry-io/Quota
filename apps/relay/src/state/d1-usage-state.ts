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
      return receiptMatches(receipt, submission, requestDigest)
        ? {
            outcome: "duplicate",
            usage_sync_revision: receipt.usage_sync_revision,
            next_sequence: receipt.sequence + 1,
          }
        : { outcome: "sequence_conflict" };
    }
    if (submission.coverage.status === "partial") {
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
    const statements = [
      this.database
        .prepare(
          `INSERT INTO usage_submissions (
             device_id, submission_id, generation, sequence, request_digest,
             usage_sync_revision, agent, start_at, end_at, accepted_at
           )
           SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10
           WHERE EXISTS (
             SELECT 1 FROM devices
             WHERE id = ?1 AND account_id = ?11 AND generation = ?3
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
          principal.account_id,
        ),
      this.database
        .prepare(
          `DELETE FROM usage_hourly
           WHERE device_id = ?1 AND agent = ?3
             AND bucket_start_utc >= ?4 AND bucket_start_utc < ?5
             AND EXISTS (
               SELECT 1 FROM usage_submissions
               WHERE device_id = ?1 AND submission_id = ?2
             )`,
        )
        .bind(
          principal.device_id,
          submission.submission_id,
          submission.coverage.agent,
          submission.coverage.start_at,
          submission.coverage.end_at,
        ),
      ...submission.rows.map((row) => this.insertRow(principal.device_id, submission, row)),
      this.preserveCoverageSide(principal.device_id, submission, "left"),
      this.preserveCoverageSide(principal.device_id, submission, "right"),
      this.database
        .prepare(
          `DELETE FROM usage_coverage
           WHERE device_id = ?1 AND agent = ?3 AND start_at < ?5 AND end_at > ?4
             AND EXISTS (
               SELECT 1 FROM usage_submissions
               WHERE device_id = ?1 AND submission_id = ?2
             )`,
        )
        .bind(
          principal.device_id,
          submission.submission_id,
          submission.coverage.agent,
          submission.coverage.start_at,
          submission.coverage.end_at,
        ),
      this.database
        .prepare(
          `INSERT INTO usage_coverage (
             device_id, agent, start_at, end_at, parser_revision, submission_id, accepted_at
           )
           SELECT ?1, ?3, ?4, ?5, ?6, ?2, ?7
           WHERE EXISTS (
             SELECT 1 FROM usage_submissions
             WHERE device_id = ?1 AND submission_id = ?2
           )`,
        )
        .bind(
          principal.device_id,
          submission.submission_id,
          submission.coverage.agent,
          submission.coverage.start_at,
          submission.coverage.end_at,
          submission.parser_revision,
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
      if (conflicting) {
        return { outcome: "sequence_conflict" };
      }
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
    if (query.start_at) {
      coverageParameters.push(query.start_at);
      coverageConditions.push(`coverage.end_at > ?${coverageParameters.length}`);
    }
    if (query.end_at) {
      coverageParameters.push(query.end_at);
      coverageConditions.push(`coverage.start_at < ?${coverageParameters.length}`);
    }
    coverageParameters.push(query.limit + 1);
    const coverage = await this.database
      .prepare(
        `SELECT coverage.device_id, coverage.agent, coverage.start_at, coverage.end_at,
                'complete' AS status,
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

    const truncated = rows.results.length > query.limit || coverage.results.length > query.limit;
    return {
      rows: rows.results.slice(0, query.limit).map(({ source_cost_microusd, ...row }) => ({
        ...row,
        ...(source_cost_microusd === null ? {} : { source_cost_microusd }),
      })),
      coverage: coverage.results.slice(0, query.limit),
      truncated,
    };
  }

  private insertRow(
    deviceId: string,
    submission: UsageSubmission,
    row: UsageHourlyFact,
  ): D1PreparedStatement {
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
           SELECT 1 FROM usage_submissions WHERE device_id = ?1 AND submission_id = ?2
         )`,
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
           device_id, agent, start_at, end_at, parser_revision, submission_id, accepted_at
         )
         SELECT coverage.device_id, coverage.agent, ${start}, ${end},
                coverage.parser_revision, coverage.submission_id, coverage.accepted_at
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

  private async getReceipt(
    deviceId: string,
    submissionId: string,
  ): Promise<UsageReceiptRow | null> {
    return this.database
      .prepare(
        `SELECT request_digest, generation, sequence, usage_sync_revision, agent, start_at, end_at
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
    receipt.end_at === submission.coverage.end_at
  );
}

function floorUtcHour(value: string): number {
  const instant = Date.parse(value);
  return instant - (instant % 3_600_000);
}
