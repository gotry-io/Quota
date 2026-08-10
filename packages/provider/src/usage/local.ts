import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { lstat, readdir } from "node:fs/promises";
import { join } from "node:path";
import { Rfc3339InstantSchema, UtcHourSchema } from "@gotry-io/quota-protocol";
import type {
  ContextBucket,
  CoverageReason,
  CoverageReasonCode,
  LocalUsageFile,
  NormalizedUsageEvent,
  NormalizedUsageRecord,
  UsageAgent,
  UsageDirectoryEntry,
  UsageFileDiscoveryResult,
  UsageFileInfo,
  UsageFileSystem,
  UsageScanResult,
  UsageSourceCursor,
} from "./contracts.ts";

const MAX_DISCOVERY_DEPTH = 8;
const MAX_DISCOVERY_ENTRIES = 100_000;
const MAX_USAGE_FILES = 20_000;
const MAX_JSONL_RECORDS = 2_000_000;
const MAX_JSONL_LINE_BYTES = 16 * 1024 * 1024;
const MAX_COVERAGE_REASONS = 128;

export const defaultUsageFileSystem: UsageFileSystem = {
  async stat(path) {
    const value = await lstat(path, { bigint: true });
    return {
      kind: value.isDirectory() ? "directory" : value.isFile() ? "file" : "other",
      size: safeStatSize(value.size),
      device: value.dev.toString(),
      inode: value.ino.toString(),
      birthtime_ns: value.birthtimeNs.toString(),
      modified_ns: value.mtimeNs.toString(),
    };
  },
  async readDirectory(path) {
    return (await readdir(path, { withFileTypes: true })).map((entry) => ({
      name: entry.name,
      kind: entry.isDirectory() ? "directory" : entry.isFile() ? "file" : "other",
    }));
  },
  async *readChunks(path, signal) {
    for await (const chunk of createReadStream(path, { signal })) {
      yield chunk as Buffer;
    }
  },
};

function safeStatSize(value: bigint): number {
  if (value < 0n || value > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw Object.assign(new Error("Usage source size is outside the supported range."), {
      code: "EOVERFLOW",
    });
  }
  return Number(value);
}

export async function discoverUsageFiles(options: {
  agent: UsageAgent;
  roots: readonly string[];
  fileSystem?: UsageFileSystem;
  acceptsFile(path: string): boolean;
}): Promise<UsageFileDiscoveryResult> {
  const fileSystem = options.fileSystem ?? defaultUsageFileSystem;
  const files: LocalUsageFile[] = [];
  const reasons: CoverageReason[] = [];
  const seenFiles = new Set<string>();
  let entriesVisited = 0;
  let limitReached = false;

  async function walk(path: string, depth: number): Promise<void> {
    if (limitReached) {
      return;
    }
    if (depth > MAX_DISCOVERY_DEPTH || entriesVisited >= MAX_DISCOVERY_ENTRIES) {
      limitReached = true;
      pushReason(reasons, { code: "discovery_limit" });
      return;
    }

    let info: UsageFileInfo;
    try {
      info = await fileSystem.stat(path);
    } catch (error) {
      if (!isMissing(error)) {
        pushReason(reasons, { code: reasonForReadError(error) });
      }
      return;
    }

    if (info.kind === "file") {
      if (!options.acceptsFile(path)) {
        return;
      }
      const identity = sourceIdentityMaterial(info, path);
      const sourceFileId = sha256(`${options.agent}\0${identity}`);
      if (seenFiles.has(sourceFileId)) {
        return;
      }
      if (files.length >= MAX_USAGE_FILES) {
        limitReached = true;
        pushReason(reasons, { code: "discovery_limit" });
        return;
      }
      seenFiles.add(sourceFileId);
      files.push({
        path,
        source_file_id: sourceFileId,
        size: info.size,
        modified_ns: info.modified_ns,
        identity,
      });
      return;
    }
    if (info.kind !== "directory") {
      if (depth === 0 || options.acceptsFile(path)) {
        pushReason(reasons, { code: "source_unreadable" });
      }
      return;
    }

    let entries: readonly UsageDirectoryEntry[];
    try {
      entries = await fileSystem.readDirectory(path);
    } catch (error) {
      pushReason(reasons, { code: reasonForReadError(error) });
      return;
    }
    entriesVisited += entries.length;
    if (entriesVisited > MAX_DISCOVERY_ENTRIES) {
      limitReached = true;
      pushReason(reasons, { code: "discovery_limit" });
      return;
    }
    for (const entry of [...entries].sort((left, right) => left.name.localeCompare(right.name))) {
      if (entry.kind === "directory" || entry.kind === "file") {
        await walk(join(path, entry.name), depth + 1);
      } else if (options.acceptsFile(join(path, entry.name))) {
        pushReason(reasons, { code: "source_unreadable" });
      }
    }
  }

  for (const root of [...new Set(options.roots)]) {
    await walk(root, 0);
  }
  files.sort((left, right) => left.path.localeCompare(right.path));
  return { files, reasons };
}

interface ParsedLine {
  event?: NormalizedUsageEvent;
  reason?: CoverageReasonCode;
}

export interface UsageLineParser {
  parse(value: Record<string, unknown>, cursor: UsageSourceCursor): ParsedLine;
}

export async function scanUsageFiles(options: {
  agent: UsageAgent;
  startAt: string;
  endAt: string;
  signal?: AbortSignal;
  fileSystem?: UsageFileSystem;
  discovery: UsageFileDiscoveryResult;
  createParser(): UsageLineParser;
}): Promise<UsageScanResult> {
  const { start, end } = parseCoverageRange(options.startAt, options.endAt);
  const fileSystem = options.fileSystem ?? defaultUsageFileSystem;
  const records: NormalizedUsageRecord[] = [];
  const reasons = [...options.discovery.reasons];
  let scannedSourceCount = 0;
  let recordsSeen = 0;
  let stopped = false;

  for (const file of options.discovery.files) {
    if (stopped) {
      break;
    }
    if (options.signal?.aborted) {
      pushReason(reasons, { code: "scan_cancelled" });
      break;
    }
    const before = await readMatchingFileInfo(fileSystem, file, reasons);
    if (!before) {
      continue;
    }
    scannedSourceCount += 1;
    const parser = options.createParser();
    try {
      await readJsonl(fileSystem.readChunks(file.path, options.signal), {
        onLine(line, byteOffset, unterminated) {
          recordsSeen += 1;
          if (recordsSeen > MAX_JSONL_RECORDS) {
            pushReason(reasons, { code: "record_limit" });
            stopped = true;
            return false;
          }
          const recordHash = sha256(line);
          const cursor: UsageSourceCursor = {
            source_file_id: file.source_file_id,
            byte_offset: byteOffset,
            record_hash: recordHash,
          };
          let value: unknown;
          try {
            value = JSON.parse(new TextDecoder().decode(line)) as unknown;
          } catch {
            pushReason(reasons, {
              code: unterminated ? "truncated_tail" : "malformed_json",
            });
            return true;
          }
          if (!value || typeof value !== "object" || Array.isArray(value)) {
            pushReason(reasons, {
              code: "unknown_record",
            });
            return true;
          }
          const parsed = parser.parse(value as Record<string, unknown>, cursor);
          if (parsed.reason) {
            pushReason(reasons, {
              code: parsed.reason,
            });
          }
          if (parsed.event) {
            const occurredAt = Date.parse(parsed.event.occurred_at);
            if (occurredAt >= start && occurredAt < end) {
              records.push({ event: parsed.event, cursor });
            }
          }
          return true;
        },
        onOversizedLine(_byteOffset) {
          pushReason(reasons, {
            code: "line_too_large",
          });
        },
      });
    } catch (error) {
      pushReason(reasons, {
        code: options.signal?.aborted ? "scan_cancelled" : reasonForReadError(error),
      });
    }
    const after = await readMatchingFileInfo(fileSystem, file, reasons);
    if (
      after &&
      (after.size !== before.size ||
        after.modified_ns !== before.modified_ns ||
        after.identity !== before.identity)
    ) {
      pushReason(reasons, { code: "source_changed" });
    }
  }

  const boundedReasons = reasons.slice(0, MAX_COVERAGE_REASONS);
  return {
    records,
    scanned_source_count: scannedSourceCount,
    coverage: {
      agent: options.agent,
      start_at: options.startAt,
      end_at: options.endAt,
      status: reasons.length === 0 ? "complete" : "partial",
      reasons: boundedReasons,
    },
  };
}

async function readMatchingFileInfo(
  fileSystem: UsageFileSystem,
  file: LocalUsageFile,
  reasons: CoverageReason[],
): Promise<(UsageFileInfo & { identity: string }) | undefined> {
  try {
    const info = await fileSystem.stat(file.path);
    const identity = sourceIdentityMaterial(info, file.path);
    if (info.kind !== "file" || identity !== file.identity) {
      pushReason(reasons, { code: "source_changed" });
      return undefined;
    }
    return { ...info, identity };
  } catch (error) {
    pushReason(reasons, {
      code: isMissing(error) ? "source_changed" : reasonForReadError(error),
    });
    return undefined;
  }
}

async function readJsonl(
  chunks: AsyncIterable<Uint8Array>,
  callbacks: {
    onLine(line: Uint8Array, byteOffset: number, unterminated: boolean): boolean;
    onOversizedLine(byteOffset: number): void;
  },
): Promise<void> {
  let pending = Buffer.alloc(0);
  let absoluteOffset = 0;
  let lineOffset = 0;
  let discarding = false;

  for await (const rawChunk of chunks) {
    const chunk = Buffer.from(rawChunk.buffer, rawChunk.byteOffset, rawChunk.byteLength);
    let cursor = 0;
    while (cursor < chunk.length) {
      const newline = chunk.indexOf(0x0a, cursor);
      const end = newline === -1 ? chunk.length : newline;
      const segment = chunk.subarray(cursor, end);
      if (!discarding) {
        if (pending.length + segment.length > MAX_JSONL_LINE_BYTES) {
          callbacks.onOversizedLine(lineOffset);
          pending = Buffer.alloc(0);
          discarding = true;
        } else if (segment.length > 0) {
          pending = pending.length === 0 ? Buffer.from(segment) : Buffer.concat([pending, segment]);
        }
      }
      if (newline === -1) {
        absoluteOffset += chunk.length - cursor;
        break;
      }
      absoluteOffset += newline - cursor + 1;
      if (!discarding && pending.length > 0) {
        const line = pending[pending.length - 1] === 0x0d ? pending.subarray(0, -1) : pending;
        if (line.length > 0 && !callbacks.onLine(line, lineOffset, false)) {
          return;
        }
      }
      pending = Buffer.alloc(0);
      discarding = false;
      lineOffset = absoluteOffset;
      cursor = newline + 1;
    }
  }
  if (!discarding && pending.length > 0) {
    const line = pending[pending.length - 1] === 0x0d ? pending.subarray(0, -1) : pending;
    if (line.length > 0) {
      callbacks.onLine(line, lineOffset, true);
    }
  }
}

function sourceIdentityMaterial(info: UsageFileInfo, path: string): string {
  return info.device !== "0" || info.inode !== "0"
    ? `${info.device}:${info.inode}`
    : `fallback:${sha256(path)}:${info.birthtime_ns}`;
}

function reasonForReadError(error: unknown): CoverageReasonCode {
  return errorCode(error) === "EACCES" || errorCode(error) === "EPERM"
    ? "permission_denied"
    : "source_unreadable";
}

function isMissing(error: unknown): boolean {
  return errorCode(error) === "ENOENT" || errorCode(error) === "ENOTDIR";
}

function errorCode(error: unknown): string | undefined {
  return error && typeof error === "object" && "code" in error && typeof error.code === "string"
    ? error.code
    : undefined;
}

function pushReason(reasons: CoverageReason[], reason: CoverageReason): void {
  if (reasons.length < MAX_COVERAGE_REASONS) {
    reasons.push(reason);
  }
}

function sha256(value: string | Uint8Array): string {
  return createHash("sha256").update(value).digest("hex");
}

function parseCoverageRange(startAt: string, endAt: string): { start: number; end: number } {
  const parsedStart = UtcHourSchema.safeParse(startAt);
  const parsedEnd = UtcHourSchema.safeParse(endAt);
  const start = parsedStart.success ? Date.parse(parsedStart.data) : Number.NaN;
  const end = parsedEnd.success ? Date.parse(parsedEnd.data) : Number.NaN;
  if (!Number.isFinite(start) || !Number.isFinite(end) || start >= end) {
    throw new TypeError("Usage scan range must use increasing canonical UTC-hour boundaries.");
  }
  return { start, end };
}

export function canonicalInstant(value: unknown): string | undefined {
  const parsed = Rfc3339InstantSchema.safeParse(value);
  if (!parsed.success) {
    return undefined;
  }
  return new Date(parsed.data).toISOString();
}

export function contextBucket(inputTokens: number): ContextBucket {
  if (inputTokens <= 128_000) return "le_128k";
  if (inputTokens <= 200_000) return "gt_128k_le_200k";
  if (inputTokens <= 256_000) return "gt_200k_le_256k";
  if (inputTokens <= 272_000) return "gt_256k_le_272k";
  return "gt_272k";
}

export function record(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

export function safeCount(value: unknown): number | undefined {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : undefined;
}

export function safeSum(...values: number[]): number | undefined {
  const total = values.reduce((sum, value) => sum + value, 0);
  return Number.isSafeInteger(total) ? total : undefined;
}

export function boundedDimension(value: unknown): string | undefined {
  return typeof value === "string" && /^[A-Za-z0-9][A-Za-z0-9._:+-]{0,63}$/.test(value)
    ? value
    : undefined;
}

export function boundedModel(value: unknown): string | undefined {
  return typeof value === "string" && /^[A-Za-z0-9][A-Za-z0-9._:/+-]{0,127}$/.test(value)
    ? value
    : undefined;
}
