import {
  LEADERBOARD_PERIOD,
  type LeaderboardResponse,
  LeaderboardResponseSchema,
  MANAGED_DATA_PROTOCOL_VERSION,
  MAXIMUM_LEADERBOARD_ENTRIES,
} from "@gotry-io/quota-protocol";
import type { AccountState, UsageState } from "@gotry-io/relay-core";
import { canonicalDigest } from "./security.ts";

/** How long a shared cache may hold the board before asking again. */
export const LEADERBOARD_MAX_AGE_SECONDS = 300;

/** The board's window, in UTC days including today. */
const LEADERBOARD_DAYS = 30;

export interface LeaderboardReadInput {
  state: Pick<AccountState, "leaderboardVersionStamp">;
  usageState: Pick<UsageState, "queryLeaderboard">;
  checkedAt: Date;
}

export interface LeaderboardRead {
  /** The validator for this answer, already quoted. */
  etag: string;
  /**
   * The board itself, folded only when a caller asks for it.
   *
   * The validator is derived from the listed set and what those Accounts have uploaded, so a
   * caller holding the current board is told so without the rollup being read at all. The
   * board is the one answer everyone asks for, which is what makes that worth separating.
   */
  payload(): Promise<LeaderboardResponse>;
}

/**
 * The last 30 UTC days, ranked, for whoever asks.
 *
 * There is no principal anywhere in this path and no handle either: the board is the same
 * bytes for every reader, which is what lets a shared cache hold it
 * ([ADR 0045](../../docs/decisions/0045-the-leaderboard-is-a-page-you-opt-into.md)).
 */
export async function readLeaderboard(input: LeaderboardReadInput): Promise<LeaderboardRead> {
  const stamp = await input.state.leaderboardVersionStamp();
  // The window is bounded by today's UTC date, so the board turns over on the day even with
  // no upload behind it.
  const rollover = input.checkedAt.toISOString().slice(0, 10);
  const etag = `"${await canonicalDigest({
    leaderboard: 1,
    period: LEADERBOARD_PERIOD,
    stamp,
    rollover,
  })}"`;
  return {
    etag,
    async payload(): Promise<LeaderboardResponse> {
      const from = new Date(input.checkedAt.getTime() - (LEADERBOARD_DAYS - 1) * 86_400_000)
        .toISOString()
        .slice(0, 10);
      const rows = await input.usageState.queryLeaderboard({
        from,
        limit: MAXIMUM_LEADERBOARD_ENTRIES,
      });
      return LeaderboardResponseSchema.parse({
        protocol_version: MANAGED_DATA_PROTOCOL_VERSION,
        period: LEADERBOARD_PERIOD,
        generated_at: input.checkedAt.toISOString(),
        entries: rows.map((row, index) => ({
          handle: row.handle,
          total_tokens: row.total_tokens,
          messages: row.messages,
          rank: index + 1,
        })),
      });
    },
  };
}
