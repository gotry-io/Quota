import type { LeaderboardResponse } from "@gotry-io/quota-protocol";
import { formatCount } from "./format.ts";

/**
 * The one sentence a link preview shows, and the board's own summary line.
 *
 * It names the shape of the board — how many places and what the top of it ran — and nothing
 * about who is reading it. An empty board says so rather than describing a leader it has not
 * got.
 */
export function leaderboardSummary(board: LeaderboardResponse): string {
  const leader = board.entries[0];
  if (!leader) {
    return "The Quota leaderboard ranks coding-agent Usage over the last 30 days. Nobody is listed yet.";
  }
  return `${board.entries.length} people rank their coding-agent Usage on Quota over the last 30 days, led by ${leader.handle} at ${formatCount(leader.total_tokens)} tokens.`;
}
