import type {
  DevicePrincipal,
  StoredUsageDailyRow,
  UsageDailyQuery,
  UsageDailyResult,
  UsageState,
  UsageUpload,
  UsageWriteResult,
} from "@gotry-io/relay-core";

/** The identity dimensions of a stored row, in the order both tables key them. */
const identityColumns = [
  "billing_channel",
  "channel_source",
  "model",
  "context_bucket",
  "service_tier",
  "speed",
  "inference_geo",
] as const;

/** The measured columns, in the order both tables carry them. */
const countColumns = [
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
] as const;

interface DeviceUsageControlRow {
  generation: number;
  deleted_before: string | null;
}

interface StoredDailyRow extends Omit<StoredUsageDailyRow, "source_cost_microusd"> {
  source_cost_microusd: string | null;
}

export class D1UsageState implements UsageState {
  constructor(private readonly database: D1Database) {}

  /**
   * Replace the hours this scan read more recently than the stored one, and rewrite the UTC
   * dates that changed, in one batch.
   *
   * There is no submission id, sequence, or receipt: an hour carries the version of the scan
   * behind it, so re-sending one is a comparison rather than a write, and a crash after commit
   * is answered by the same comparison instead of by a remembered outcome.
   */
  async recordUsage(
    principal: DevicePrincipal,
    upload: UsageUpload,
    receivedAt: string,
  ): Promise<UsageWriteResult> {
    const device = await this.database
      .prepare(
        `SELECT generation, deleted_before
         FROM devices
         WHERE id = ?1 AND account_id = ?2 AND signed_out_at IS NULL AND deleted_at IS NULL`,
      )
      .bind(principal.device_id, principal.account_id)
      .first<DeviceUsageControlRow>();
    if (
      !device ||
      device.generation !== principal.generation ||
      upload.generation !== principal.generation
    ) {
      return { outcome: "stale_device" };
    }

    // A new generation may rebuild the watermark's own UTC hour, but nothing before it.
    const watermark = device.deleted_before === null ? null : floorUtcHour(device.deleted_before);
    const stored = await this.storedScanVersions(
      principal.device_id,
      upload.agent,
      upload.hours.map((hour) => hour.bucket_start_utc),
    );

    const accepted: UsageUpload["hours"][number][] = [];
    const ignored: string[] = [];
    for (const hour of upload.hours) {
      const current = stored.get(hour.bucket_start_utc);
      const beforeWatermark = watermark !== null && Date.parse(hour.bucket_start_utc) < watermark;
      if (beforeWatermark || (current !== undefined && hour.scan_version <= current)) {
        ignored.push(hour.bucket_start_utc);
        continue;
      }
      accepted.push(hour);
    }
    if (accepted.length === 0) {
      return { outcome: "written", accepted: [], ignored };
    }

    const statements: D1PreparedStatement[] = [];
    for (const hour of accepted) {
      statements.push(this.replaceHour(principal, upload.agent, hour));
    }
    for (const date of [...new Set(accepted.map((hour) => hour.bucket_start_utc.slice(0, 10)))]) {
      statements.push(
        this.clearDay(principal.device_id, upload.agent, date),
        this.rollUpDay(principal.device_id, upload.agent, date),
      );
    }
    statements.push(this.markDeviceSeen(principal, receivedAt));
    await this.database.batch(statements);
    return {
      outcome: "written",
      accepted: accepted.map((hour) => hour.bucket_start_utc),
      ignored,
    };
  }

  async queryDailyUsage(accountId: string, query: UsageDailyQuery): Promise<UsageDailyResult> {
    const parameters: (string | number)[] = [accountId];
    const conditions = ["devices.account_id = ?1", "devices.deleted_at IS NULL"];
    if (query.from) {
      parameters.push(query.from);
      conditions.push(`daily.utc_date >= ?${parameters.length}`);
    }
    if (query.to) {
      parameters.push(query.to);
      conditions.push(`daily.utc_date <= ?${parameters.length}`);
    }
    parameters.push(query.limit + 1);
    const rows = await this.database
      .prepare(
        `SELECT daily.device_id, daily.utc_date AS date, daily.agent,
                ${identityColumns.map((column) => `daily.${column}`).join(", ")},
                ${countColumns.map((column) => `daily.${column}`).join(", ")},
                daily.source_cost_microusd, daily.source_cost_covered_requests,
                daily.partial_hours
         FROM usage_daily AS daily
         INNER JOIN devices ON devices.id = daily.device_id
         WHERE ${conditions.join(" AND ")}
         ORDER BY daily.utc_date ASC, daily.device_id ASC, daily.agent ASC,
                  ${identityColumns.map((column) => `daily.${column} ASC`).join(", ")}
         LIMIT ?${parameters.length}`,
      )
      .bind(...parameters)
      .all<StoredDailyRow>();
    return {
      rows: rows.results.slice(0, query.limit).map(({ source_cost_microusd, ...row }) => ({
        ...row,
        ...(source_cost_microusd === null ? {} : { source_cost_microusd }),
      })),
      truncated: rows.results.length > query.limit,
    };
  }

  /**
   * The newest scan already stored for each named hour.
   *
   * The wanted hours travel as one JSON array rather than as a bound list, because an upload may
   * name more hours than D1 allows bound parameters, and as a range they would drag in every
   * hour between the first and the last.
   */
  private async storedScanVersions(
    deviceId: string,
    agent: string,
    buckets: readonly string[],
  ): Promise<Map<string, number>> {
    if (buckets.length === 0) return new Map();
    const rows = await this.database
      .prepare(
        `SELECT facts.bucket_start_utc AS bucket, MAX(facts.scan_version) AS scan_version
         FROM usage_hourly AS facts
         INNER JOIN json_each(?3) AS wanted ON wanted.value = facts.bucket_start_utc
         WHERE facts.device_id = ?1 AND facts.agent = ?2
         GROUP BY facts.bucket_start_utc`,
      )
      .bind(deviceId, agent, JSON.stringify(buckets))
      .all<{ bucket: string; scan_version: number }>();
    return new Map(rows.results.map((row) => [row.bucket, row.scan_version]));
  }

  private replaceHour(
    principal: DevicePrincipal,
    agent: string,
    hour: UsageUpload["hours"][number],
  ): D1PreparedStatement {
    // One statement, whatever the row count: an hour may carry hundreds of rows and D1 bounds
    // both the parameters a statement may bind and the statements a batch may hold.
    return this.database
      .prepare(
        `INSERT INTO usage_hourly (
           device_id, agent, bucket_start_utc, scan_version, partial,
           ${identityColumns.join(", ")},
           ${countColumns.join(", ")},
           source_cost_microusd, source_cost_covered_requests
         )
         SELECT ?1, ?2, ?3, ?4, ?5,
                ${identityColumns.map((column) => `json_extract(item.value, '$.${column}')`).join(",\n                ")},
                ${countColumns.map((column) => `json_extract(item.value, '$.${column}')`).join(",\n                ")},
                json_extract(item.value, '$.source_cost_microusd'),
                json_extract(item.value, '$.source_cost_covered_requests')
         FROM json_each(?6) AS item
         WHERE ${deviceIsCurrent}`,
      )
      .bind(
        principal.device_id,
        agent,
        hour.bucket_start_utc,
        hour.scan_version,
        hour.partial ? 1 : 0,
        JSON.stringify(hour.rows),
        principal.account_id,
        principal.generation,
      );
  }

  private clearDay(deviceId: string, agent: string, date: string): D1PreparedStatement {
    return this.database
      .prepare("DELETE FROM usage_daily WHERE device_id = ?1 AND utc_date = ?2 AND agent = ?3")
      .bind(deviceId, date, agent);
  }

  /** Rebuild one UTC date from the hours that survived this batch's replacements. */
  private rollUpDay(deviceId: string, agent: string, date: string): D1PreparedStatement {
    return this.database
      .prepare(
        `INSERT INTO usage_daily (
           device_id, utc_date, agent,
           ${identityColumns.join(", ")},
           ${countColumns.join(", ")},
           source_cost_microusd, source_cost_covered_requests, partial_hours
         )
         SELECT ?1, ?2, ?3,
                ${identityColumns.join(", ")},
                ${countColumns.map((column) => `SUM(${column})`).join(", ")},
                CASE
                  WHEN SUM(source_cost_covered_requests) > 0
                    THEN CAST(SUM(CAST(COALESCE(source_cost_microusd, '0') AS INTEGER)) AS TEXT)
                  ELSE NULL
                END,
                SUM(source_cost_covered_requests),
                SUM(partial)
         FROM usage_hourly
         WHERE device_id = ?1 AND agent = ?3
           AND bucket_start_utc >= ?4 AND bucket_start_utc < ?5
         GROUP BY ${identityColumns.join(", ")}`,
      )
      .bind(deviceId, date, agent, `${date}T00:00:00Z`, `${nextUtcDate(date)}T00:00:00Z`);
  }

  private markDeviceSeen(principal: DevicePrincipal, receivedAt: string): D1PreparedStatement {
    return this.database
      .prepare(
        `UPDATE devices
         SET usage_sync_revision = usage_sync_revision + 1, last_seen_at = ?3
         WHERE id = ?1 AND account_id = ?4 AND generation = ?2
           AND signed_out_at IS NULL AND deleted_at IS NULL`,
      )
      .bind(principal.device_id, principal.generation, receivedAt, principal.account_id);
  }
}

/**
 * A device that was deleted, signed out, or moved to a new generation between the check and the
 * batch must not have this upload land. The batch is one transaction, so this guard decides it.
 */
const deviceIsCurrent = `EXISTS (
             SELECT 1 FROM devices
             WHERE id = ?1 AND account_id = ?7 AND generation = ?8
               AND signed_out_at IS NULL AND deleted_at IS NULL
           )`;

function nextUtcDate(date: string): string {
  return new Date(Date.parse(`${date}T00:00:00Z`) + 86_400_000).toISOString().slice(0, 10);
}

function floorUtcHour(value: string): number {
  const instant = Date.parse(value);
  return instant - (instant % 3_600_000);
}
