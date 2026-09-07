import type { LeaderboardResponse, PublicUsageResponse } from "@gotry-io/quota-protocol";
import { env } from "$env/dynamic/private";
import type { WebDocumentPort, WebLeaderboardView } from "./document-port.ts";

/**
 * The document port `pnpm dev:web` runs against, where there is no Worker and so no D1.
 *
 * `QUOTA_DEV_VIEWER` is the header stub described in
 * [ADR 0011](../../../../../docs/decisions/0011-sveltekit-document-worker.md);
 * `QUOTA_DEV_PUBLIC_HANDLE` is the same idea for a public page, and answers that one handle
 * with a fixed sample so the page and its share card can be looked at; it is also the handle
 * the sample leaderboard treats as the reader's own. All of this exists only while
 * `dev === true`: in production the port comes from Relay and this module is never reached.
 */
export function devDocumentPort(): WebDocumentPort {
  return {
    async getViewer(headers) {
      if (headers.get("x-quota-dev-signed-out") === "1") return null;
      const label = env.QUOTA_DEV_VIEWER?.trim();
      return label ? { displayLabel: label } : null;
    },
    async readPublicProfile(handle: string) {
      const published = env.QUOTA_DEV_PUBLIC_HANDLE?.trim();
      return published && published === handle ? devPublicProfile(handle) : null;
    },
    async readLeaderboard(): Promise<WebLeaderboardView> {
      const published = env.QUOTA_DEV_PUBLIC_HANDLE?.trim();
      return {
        board: devLeaderboard(),
        viewerHandle: published ? published : null,
      };
    },
  };
}

/** A board with a plausible spread, so the page can be looked at without a D1 behind it. */
function devLeaderboard(): LeaderboardResponse {
  const handles = [
    "octocat",
    "kyle",
    "mira",
    "tsuki",
    "devon",
    "ana-b",
    "quiet-fox",
    "rk",
    "sam-p",
    "hal9000",
  ];
  return {
    protocol_version: 6,
    period: "30d",
    generated_at: "2026-09-06T12:00:00.000Z",
    entries: handles.map((handle, index) => ({
      handle,
      total_tokens: Math.round(38_400_000 / (index + 1.35)),
      messages: Math.round(12_800 / (index + 1.35)),
      rank: index + 1,
    })),
  };
}

function devPublicProfile(handle: string): PublicUsageResponse {
  const generatedAt = new Date("2026-09-06T12:00:00Z");
  return {
    protocol_version: 6,
    handle,
    published_at: "2026-06-01T09:00:00Z",
    generated_at: generatedAt.toISOString(),
    last_30_days: {
      totals: {
        total_tokens: 11_420_000,
        input_tokens: 8_640_000,
        output_tokens: 2_780_000,
        messages: 4_120,
      },
      cost: { amount_microusd: "8503200", status: "complete" },
      providers: [
        { provider: "anthropic", total_tokens: 6_400_000, share_permille: 560 },
        { provider: "openai", total_tokens: 3_600_000, share_permille: 315 },
        { provider: "google", total_tokens: 1_420_000, share_permille: 125 },
      ],
      models: [
        {
          provider: "anthropic",
          model: "claude-opus-5",
          total_tokens: 4_100_000,
          share_permille: 359,
        },
        {
          provider: "openai",
          model: "gpt-5.6-sol",
          total_tokens: 2_800_000,
          share_permille: 245,
        },
        {
          provider: "anthropic",
          model: "claude-sonnet-5",
          total_tokens: 2_300_000,
          share_permille: 201,
        },
        {
          provider: "google",
          model: "gemini-3-pro",
          total_tokens: 1_420_000,
          share_permille: 124,
        },
        { provider: "openai", model: "gpt-5.6-mini", total_tokens: 800_000, share_permille: 70 },
      ],
    },
    all: {
      totals: {
        total_tokens: 96_300_000,
        input_tokens: 72_100_000,
        output_tokens: 24_200_000,
        messages: 38_400,
      },
      cost: { amount_microusd: "71204000", status: "partial" },
      providers: [
        { provider: "anthropic", total_tokens: 52_000_000, share_permille: 540 },
        { provider: "openai", total_tokens: 33_000_000, share_permille: 343 },
        { provider: "google", total_tokens: 8_300_000, share_permille: 86 },
        { provider: "xai", total_tokens: 3_000_000, share_permille: 31 },
      ],
      models: [
        {
          provider: "anthropic",
          model: "claude-opus-5",
          total_tokens: 31_000_000,
          share_permille: 322,
        },
        {
          provider: "openai",
          model: "gpt-5.6-sol",
          total_tokens: 24_000_000,
          share_permille: 249,
        },
        {
          provider: "anthropic",
          model: "claude-sonnet-5",
          total_tokens: 21_000_000,
          share_permille: 218,
        },
      ],
    },
    activity: devActivity(generatedAt),
  };
}

/** A year that looks like a year: busier on weekdays, with a quiet stretch in the middle. */
function devActivity(generatedAt: Date): PublicUsageResponse["activity"] {
  const days: PublicUsageResponse["activity"] = [];
  for (let back = 364; back >= 0; back -= 1) {
    const date = new Date(generatedAt.getTime() - back * 86_400_000);
    const weekday = date.getUTCDay();
    if (weekday === 0 || weekday === 6) continue;
    if (back > 150 && back < 190) continue;
    const level = 1 + ((back * 7 + weekday) % 4);
    days.push({ date: date.toISOString().slice(0, 10), level });
  }
  return days;
}
