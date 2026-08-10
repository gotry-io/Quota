import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  claudeUsageRoots,
  codexUsageRoots,
  discoverClaudeUsageFiles,
  discoverCodexUsageFiles,
  discoverGrokUsageFiles,
  discoverOpenCodeUsageFiles,
  discoverPiUsageFiles,
  grokUsageRoots,
  openCodeUsageRoots,
  piUsageRoots,
  scanClaudeUsage,
  scanCodexUsage,
  scanGrokUsage,
  scanOpenCodeUsage,
  scanPiUsage,
  type UsageFileSystem,
} from "../src/index.ts";

const FIXTURES = fileURLToPath(new URL("./fixtures/usage", import.meta.url));
const RANGE = {
  startAt: "2026-08-02T00:00:00Z",
  endAt: "2026-08-03T00:00:00Z",
};

describe("usage discovery", () => {
  it("uses only bounded canonical roots or explicitly injected roots", () => {
    expect(codexUsageRoots({ homeDirectory: "/home/quota", environment: {} })).toEqual([
      "/home/quota/.codex/sessions",
      "/home/quota/.codex/archived_sessions",
    ]);
    expect(
      codexUsageRoots({
        homeDirectory: "/home/quota",
        environment: { CODEX_HOME: "/var/codex" },
      }),
    ).toEqual(["/var/codex/sessions", "/var/codex/archived_sessions"]);
    expect(claudeUsageRoots({ homeDirectory: "/home/quota", environment: {} })).toEqual([
      "/home/quota/.claude/projects",
    ]);
    expect(
      claudeUsageRoots({
        homeDirectory: "/home/quota",
        environment: { CLAUDE_CONFIG_DIR: "/var/claude" },
      }),
    ).toEqual(["/var/claude/projects"]);
    expect(grokUsageRoots({ homeDirectory: "/home/quota", environment: {} })).toEqual([
      "/home/quota/.grok/sessions",
      "/home/quota/.grok/trace-exports",
    ]);
    expect(openCodeUsageRoots({ homeDirectory: "/home/quota", environment: {} })).toEqual([
      "/home/quota/.local/share/opencode",
    ]);
    expect(piUsageRoots({ homeDirectory: "/home/quota", environment: {} })).toEqual([
      "/home/quota/.pi/agent/sessions",
      "/home/quota/.local/share/pi-coding-agent/sessions",
    ]);
    expect(codexUsageRoots({ roots: ["/fixture/codex"] })).toEqual(["/fixture/codex"]);
  });

  it("discovers only canonical JSONL files and returns opaque source identities", async () => {
    const codex = await discoverCodexUsageFiles({ roots: [join(FIXTURES, "codex", "sessions")] });
    const claude = await discoverClaudeUsageFiles({
      roots: [join(FIXTURES, "claude", "projects")],
    });

    expect(codex.files).toHaveLength(2);
    expect(claude.files).toHaveLength(1);
    expect(codex.files[0]?.source_file_id).toMatch(/^[a-f0-9]{64}$/);
    expect(claude.files[0]?.source_file_id).toMatch(/^[a-f0-9]{64}$/);
    expect(codex.reasons).toEqual([]);
    expect(claude.reasons).toEqual([]);
  });
});

describe("Codex local usage", () => {
  it("parses rollout variants, cumulative deltas, model switches, and cache/reasoning facts", async () => {
    const options = { ...RANGE, roots: [join(FIXTURES, "codex", "sessions")] };
    const first = await scanCodexUsage(options);
    const repeated = await scanCodexUsage(options);

    expect(first.coverage).toMatchObject({ status: "complete", reasons: [] });
    expect(first.scanned_source_count).toBe(2);
    expect(first.records).toHaveLength(2);
    expect(first.records[0]?.event).toMatchObject({
      occurred_at: "2026-08-02T10:01:00.000Z",
      agent: "codex",
      model: "gpt-5.2-codex",
      billing_channel: "openai_direct",
      channel_source: "agent_default",
      input_tokens: 1_000,
      cache_read_tokens: 200,
      cache_write_inferred_tokens: 100,
      output_tokens: 200,
      reasoning_tokens: 50,
      context_bucket: "le_128k",
      service_tier: "unknown",
      speed: "unknown",
      source_cost_covered_requests: 0,
    });
    expect(first.records[1]?.event).toMatchObject({
      occurred_at: "2026-08-02T11:01:00.000Z",
      model: "gpt-5.3-codex",
      input_tokens: 130_000,
      cache_read_tokens: 300,
      cache_write_inferred_tokens: 50,
      output_tokens: 300,
      reasoning_tokens: 100,
      context_bucket: "gt_128k_le_200k",
      service_tier: "priority",
      speed: "fast",
    });
    expect(first.records.map((record) => record.cursor)).toEqual(
      repeated.records.map((record) => record.cursor),
    );
    for (const record of first.records) {
      expect(record.cursor.source_file_id).toMatch(/^[a-f0-9]{64}$/);
      expect(record.cursor.record_hash).toMatch(/^[a-f0-9]{64}$/);
      expect(record.cursor.byte_offset).toBeGreaterThanOrEqual(0);
    }
    expect(privateScanJson(first)).not.toMatch(
      /PROMPT_MUST_NOT_ESCAPE|session-secret-123|\/private\/sensitive|tool_payload/,
    );
  });

  it("attributes leading inherited Usage when the file later provides its model", async () => {
    await withTemporaryUsageRoot("codex-inherited-model", async (root) => {
      const sessions = join(root, "sessions");
      await mkdir(sessions, { recursive: true });
      await writeFile(
        join(sessions, "rollout-inherited.jsonl"),
        [
          JSON.stringify({
            timestamp: "2026-08-02T10:01:00.000Z",
            type: "event_msg",
            payload: {
              type: "token_count",
              info: {
                last_token_usage: {
                  input_tokens: 10,
                  cached_input_tokens: 2,
                  output_tokens: 1,
                  reasoning_output_tokens: 0,
                },
              },
            },
          }),
          JSON.stringify({
            timestamp: "2026-08-02T10:01:01.000Z",
            type: "turn_context",
            payload: { model: "gpt-5.6-sol" },
          }),
        ].join("\n"),
      );

      const result = await scanCodexUsage({ ...RANGE, roots: [sessions] });
      expect(result.coverage.status).toBe("complete");
      expect(result.records).toHaveLength(1);
      expect(result.records[0]?.event).toMatchObject({
        model: "gpt-5.6-sol",
        input_tokens: 10,
        output_tokens: 1,
      });
    });
  });

  it("marks unknown, unsafe, subset-breaking, and truncated records partial", async () => {
    await withTemporaryUsageRoot("codex-partial", async (root) => {
      const sessions = join(root, "sessions");
      await mkdir(sessions, { recursive: true });
      await writeFile(
        join(sessions, "rollout-partial.jsonl"),
        [
          JSON.stringify({
            timestamp: "2026-08-02T10:00:00.000Z",
            type: "turn_context",
            payload: { model: "gpt-5.2-codex" },
          }),
          JSON.stringify({
            timestamp: "2026-08-02T10:01:00.000Z",
            type: "event_msg",
            payload: {
              type: "token_count",
              info: {
                last_token_usage: {
                  input_tokens: 10,
                  cached_input_tokens: 11,
                  output_tokens: 1,
                  reasoning_output_tokens: 0,
                  total_tokens: 11,
                },
              },
            },
          }),
          JSON.stringify({
            timestamp: "2026-08-02T10:02:00.000Z",
            type: "event_msg",
            payload: {
              type: "token_count",
              info: {
                last_token_usage: {
                  input_tokens: Number.MAX_SAFE_INTEGER + 1,
                  cached_input_tokens: 0,
                  output_tokens: 1,
                  reasoning_output_tokens: 0,
                },
              },
            },
          }),
          JSON.stringify({ type: "future_usage", usage: { tokens: 1 } }),
          '{"timestamp":"2026-08-02T10:03:00.000Z","type":"event_msg"',
        ].join("\n"),
      );

      const result = await scanCodexUsage({ ...RANGE, roots: [sessions] });
      expect(result.records).toEqual([]);
      expect(result.coverage.status).toBe("partial");
      expect(result.coverage.reasons.map((reason) => reason.code)).toEqual([
        "invalid_usage",
        "invalid_usage",
        "unknown_record",
        "truncated_tail",
      ]);
    });
  });
});

describe("additional local Usage agents", () => {
  it("parses Grok per-response usage without reading transcript content", async () => {
    await withTemporaryUsageRoot("grok-usage", async (root) => {
      const sessions = join(root, "sessions");
      await mkdir(sessions, { recursive: true });
      await writeFile(
        join(sessions, "events.jsonl"),
        [
          JSON.stringify({
            type: "turn_started",
            ts: "2026-08-02T09:00:00.000Z",
            model_id: "grok-4.5",
          }),
          JSON.stringify({
            type: "usage",
            ts: "2026-08-02T09:01:00.000Z",
            usage: {
              input_tokens: 100,
              cache_read_input_tokens: 20,
              cache_creation_input_tokens: 5,
              output_tokens: 30,
              reasoning_tokens: 10,
              cost_in_usd_ticks: "120000",
              server_tool_use: { web_search_requests: 1 },
            },
          }),
        ].join("\n"),
      );

      const discovered = await discoverGrokUsageFiles({ roots: [sessions] });
      const result = await scanGrokUsage({ ...RANGE, roots: [sessions] });
      expect(discovered.files).toHaveLength(1);
      expect(result.coverage.status).toBe("complete");
      expect(result.records[0]?.event).toMatchObject({
        agent: "grok",
        model: "grok-4.5",
        billing_channel: "xai_direct",
        input_tokens: 125,
        cache_read_tokens: 20,
        cache_write_inferred_tokens: 5,
        output_tokens: 30,
        reasoning_tokens: 10,
        billable_tools: { web_search: 1 },
        source_cost_microusd: 12n,
      });
    });
  });

  it("reads OpenCode's SQLite message store and drops zero-token messages", async () => {
    await withTemporaryUsageRoot("opencode-usage", async (root) => {
      const database = new DatabaseSync(join(root, "opencode.db"));
      database.exec(
        "CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL)",
      );
      const insert = database.prepare(
        "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES (?, 'session', ?, ?, ?)",
      );
      const timestamp = Date.parse("2026-08-02T10:00:00.000Z");
      insert.run(
        "message-usage",
        timestamp,
        timestamp,
        JSON.stringify({
          role: "assistant",
          modelID: "gpt-5.6-sol",
          providerID: "openai",
          time: { created: timestamp },
          tokens: { input: 100, output: 20, reasoning: 5, cache: { read: 50, write: 10 } },
          cost: 0.01,
        }),
      );
      insert.run(
        "message-empty",
        timestamp + 1,
        timestamp + 1,
        JSON.stringify({
          role: "assistant",
          modelID: "unknown",
          providerID: "openai",
          time: { created: timestamp + 1 },
          tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
          cost: 0,
        }),
      );
      const outsideRange = Date.parse("2025-01-01T00:00:00.000Z");
      insert.run(
        "message-outside-range",
        outsideRange,
        outsideRange,
        JSON.stringify({
          role: "assistant",
          modelID: "gpt-5.6-sol",
          providerID: "openai",
          time: { created: outsideRange },
        }),
      );
      database.close();

      const discovered = await discoverOpenCodeUsageFiles({ roots: [root] });
      const result = await scanOpenCodeUsage({ ...RANGE, roots: [root] });
      expect(discovered.files).toHaveLength(1);
      expect(result.coverage.status).toBe("complete");
      expect(result.records).toHaveLength(1);
      expect(result.records[0]?.event).toMatchObject({
        agent: "opencode",
        model: "gpt-5.6-sol",
        billing_channel: "openai_direct",
        input_tokens: 160,
        cache_read_tokens: 50,
        cache_write_inferred_tokens: 10,
        output_tokens: 20,
        reasoning_tokens: 5,
        source_cost_microusd: 10_000n,
      });
    });
  });

  it("parses Pi assistant usage and ignores unknown models", async () => {
    await withTemporaryUsageRoot("pi-usage", async (root) => {
      await writeFile(
        join(root, "session.jsonl"),
        [
          JSON.stringify({ type: "session", version: 3, timestamp: "2026-08-02T00:00:00Z" }),
          JSON.stringify({
            type: "message",
            timestamp: "2026-08-02T11:00:00Z",
            message: {
              role: "assistant",
              provider: "anthropic",
              model: "claude-sonnet-4-6",
              timestamp: Date.parse("2026-08-02T11:00:00Z"),
              usage: {
                input: 100,
                output: 40,
                cacheRead: 20,
                cacheWrite: 10,
                reasoning: 5,
                cost: { total: 0.02 },
              },
            },
          }),
          JSON.stringify({
            type: "message",
            message: {
              role: "assistant",
              provider: "anthropic",
              model: "unknown",
              timestamp: Date.parse("2026-08-02T12:00:00Z"),
              usage: {
                input: 10,
                output: 1,
                cacheRead: 0,
                cacheWrite: 0,
                cost: { total: 0 },
              },
            },
          }),
        ].join("\n"),
      );

      const discovered = await discoverPiUsageFiles({ roots: [root] });
      const result = await scanPiUsage({ ...RANGE, roots: [root] });
      expect(discovered.files).toHaveLength(1);
      expect(result.coverage.status).toBe("complete");
      expect(result.records).toHaveLength(1);
      expect(result.records[0]?.event).toMatchObject({
        agent: "pi",
        model: "claude-sonnet-4-6",
        billing_channel: "anthropic_direct",
        input_tokens: 130,
        output_tokens: 40,
        reasoning_tokens: 5,
        source_cost_microusd: 20_000n,
      });
    });
  });
});

describe("Claude Code local usage", () => {
  it("parses legacy and detailed cache records, dimensions, tools, reasoning, and source cost", async () => {
    const result = await scanClaudeUsage({
      ...RANGE,
      roots: [join(FIXTURES, "claude", "projects")],
    });

    expect(result.coverage).toMatchObject({ status: "complete", reasons: [] });
    expect(result.records).toHaveLength(2);
    expect(result.records[0]?.event).toMatchObject({
      occurred_at: "2026-08-02T12:00:00.000Z",
      agent: "claude_code",
      model: "synthetic",
      billing_channel: "unknown",
      channel_source: "unknown",
      input_tokens: 135,
      cache_read_tokens: 10,
      cache_write_5m_tokens: 0,
      cache_write_1h_tokens: 0,
      cache_write_inferred_tokens: 25,
      output_tokens: 50,
      reasoning_tokens: 0,
      inference_geo: "unknown",
      source_cost_microusd: 120_000n,
      source_cost_covered_requests: 1,
    });
    expect(result.records[1]?.event).toMatchObject({
      occurred_at: "2026-08-02T13:00:00.000Z",
      model: "claude-opus-4-6",
      input_tokens: 710,
      cache_read_tokens: 400,
      cache_write_5m_tokens: 100,
      cache_write_1h_tokens: 200,
      cache_write_inferred_tokens: 0,
      output_tokens: 100,
      reasoning_tokens: 40,
      service_tier: "priority",
      speed: "fast",
      inference_geo: "us",
      billable_tools: { web_search: 2, web_fetch: 1 },
      source_cost_covered_requests: 0,
    });
    expect(privateScanJson(result)).not.toMatch(
      /COMPLETION_MUST_NOT_ESCAPE|REASONING_MUST_NOT_ESCAPE|TOOL_PAYLOAD_MUST_NOT_ESCAPE|session-secret|message-secret|request-secret|\/private\/claude/,
    );
  });

  it("reports permission failures as partial without reading credentials or Keychain", async () => {
    let chunkReads = 0;
    const fileSystem: UsageFileSystem = {
      async stat() {
        return directoryInfo();
      },
      async readDirectory() {
        throw Object.assign(new Error("synthetic permission failure"), { code: "EACCES" });
      },
      async *readChunks() {
        chunkReads += 1;
        yield new Uint8Array();
      },
    };

    const result = await scanClaudeUsage({ ...RANGE, roots: ["/synthetic/claude"], fileSystem });
    expect(result.records).toEqual([]);
    expect(result.coverage).toMatchObject({
      status: "partial",
      reasons: [{ code: "permission_denied" }],
    });
    expect(chunkReads).toBe(0);
  });
});

function privateScanJson(value: unknown): string {
  return JSON.stringify(value, (_key, item) => (typeof item === "bigint" ? item.toString() : item));
}

function directoryInfo() {
  return {
    kind: "directory" as const,
    size: 0,
    device: "1",
    inode: "1",
    birthtime_ns: "0",
    modified_ns: "0",
  };
}

async function withTemporaryUsageRoot(
  prefix: string,
  action: (root: string) => Promise<void>,
): Promise<void> {
  const root = await mkdtemp(join(tmpdir(), `${prefix}-`));
  try {
    await action(root);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}
