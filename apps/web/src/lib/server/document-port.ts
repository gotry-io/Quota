import type { LeaderboardResponse, PublicUsageResponse } from "@gotry-io/quota-protocol";

export interface WebDocumentViewer {
  displayLabel: string;
}

/**
 * The board, plus which row on it belongs to whoever is reading.
 *
 * The board itself is the same for everyone and is the cacheable artifact; the one thing that
 * differs per reader is which handle is theirs, and that is answered here rather than by a
 * second load asking who the viewer is
 * ([ADR 0045](../../../../../docs/decisions/0045-the-leaderboard-is-a-page-you-opt-into.md)).
 */
export interface WebLeaderboardView {
  board: LeaderboardResponse;
  /** The reader's own published handle, or null when they have none or are signed out. */
  viewerHandle: string | null;
}

export interface WebDocumentPort {
  getViewer(headers: Headers): Promise<WebDocumentViewer | null>;
  /**
   * The public page published under this handle, or null when there is none.
   *
   * A document load may reach account data only through this port, and this is the second
   * thing it may ask for: a page whose whole address is the handle in the URL, with no session
   * anywhere in the answer
   * ([ADR 0037](../../../../../docs/decisions/0037-a-public-profile-shows-usage-not-quota.md)).
   */
  readPublicProfile(handle: string): Promise<PublicUsageResponse | null>;
  /**
   * The leaderboard, and the reader's own place on it.
   *
   * The headers are read for one question — which handle is the reader's — and nothing else
   * about the Account reaches the load.
   */
  readLeaderboard(headers: Headers): Promise<WebLeaderboardView>;
}
