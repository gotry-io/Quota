import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import type { LeaderboardResponse } from "@gotry-io/quota-protocol";
import { leaderboardSummary } from "../src/lib/leaderboard.ts";
import { isPublishedPagePath, LEADERBOARD_PATH } from "../src/lib/routes.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

function board(entries: LeaderboardResponse["entries"]): LeaderboardResponse {
  return {
    protocol_version: 6,
    period: "30d",
    generated_at: "2026-09-06T12:00:00Z",
    entries,
  };
}

test("the board's summary names its size and its leader, and nothing else", () => {
  const summary = leaderboardSummary(
    board([
      { handle: "kyle", total_tokens: 11_420_000, messages: 4_120, rank: 1 },
      { handle: "mira", total_tokens: 9_000_000, messages: 3_000, rank: 2 },
    ]),
  );
  assert.match(summary, /2 people/);
  assert.match(summary, /kyle/);
  assert.match(summary, /11\.4M tokens/);
  assert.equal(summary.includes("mira"), false);

  assert.match(leaderboardSummary(board([])), /Nobody is listed yet\./);
});

test("the board wears the published chrome rather than the account shell", () => {
  assert.equal(isPublishedPagePath(LEADERBOARD_PATH), true);
  assert.equal(isPublishedPagePath("/leaderboards"), false);
  assert.equal(isPublishedPagePath("/my"), false);
});

test("the board states its own head and loads only through the document port", () => {
  const page = readFileSync(join(root, "src/routes/leaderboard/+page.svelte"), "utf8");
  assert.match(page, /<svelte:head>/);
  assert.match(page, /<title>/);
  assert.match(page, /rel="canonical"/);
  assert.match(page, /property="og:title"/);
  assert.match(page, /property="og:description"/);
  assert.match(page, /name="twitter:card"/);
  // A place on the board is a handle and two numbers. Nothing else about an Account is here.
  for (const forbidden of [
    "displayLabel",
    "account_id",
    "device_id",
    "amount_microusd",
    "used_percent",
  ]) {
    assert.equal(page.includes(forbidden), false, forbidden);
  }

  const server = readFileSync(join(root, "src/routes/leaderboard/+page.server.ts"), "utf8");
  assert.match(server, /locals\.document\.readLeaderboard\(request\.headers\)/);
  const specifiers = [...server.matchAll(/from\s+["']([^"']+)["']/g)].map((match) => match[1]);
  for (const specifier of specifiers) {
    assert.equal(specifier, "./$types", `unexpected import ${specifier}`);
  }
});
