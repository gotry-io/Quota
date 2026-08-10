import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  claudeUsageRoots,
  codexUsageRoots,
  discoverClaudeUsageFiles,
  discoverCodexUsageFiles,
  scanClaudeUsage,
  scanCodexUsage,
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
    expect(first.records).toHaveLength(3);
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
    expect(first.records[2]?.event).toMatchObject({
      occurred_at: "2026-08-02T14:01:00.000Z",
      model: "unknown",
      input_tokens: 10,
      output_tokens: 2,
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
      billing_channel: "anthropic_direct",
      channel_source: "agent_default",
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
