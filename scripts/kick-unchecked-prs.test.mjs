import assert from "node:assert/strict";
import test from "node:test";
import { COMMENT_MARKER, decide, explanation } from "./kick-unchecked-prs.mjs";

const now = Date.parse("2026-09-21T06:00:00Z");
const minutesAgo = (minutes) => new Date(now - minutes * 60_000).toISOString();
const pr = (overrides = {}) => ({
  number: 277,
  draft: false,
  sameRepository: true,
  createdAt: minutesAgo(90),
  mergeable: true,
  checkRuns: 0,
  explained: false,
  ...overrides,
});

test("a mergeable pull request whose head has no check run is dispatched", () => {
  // #277: opened in conflict, so nothing started; main moved, the conflict went, nothing started.
  assert.equal(decide(pr(), { now }).action, "dispatch");
});

test("a pull request with any check run is left alone", () => {
  assert.equal(decide(pr({ checkRuns: 1 }), { now }).action, "skip");
});

test("a pull request opened a minute ago is not judged yet", () => {
  // Check runs register about a minute after a pull request opens; #293 was closed and reopened
  // fifty seconds in because "no checks reported" was read as "no checks will ever run".
  assert.equal(decide(pr({ createdAt: minutesAgo(1) }), { now }).action, "wait");
  assert.equal(decide(pr({ createdAt: minutesAgo(10) }), { now }).action, "dispatch");
});

test("mergeability GitHub has not computed yet is not a verdict", () => {
  assert.equal(decide(pr({ mergeable: null }), { now }).action, "wait");
});

test("a pull request still in conflict is told why once, and not dispatched", () => {
  assert.equal(decide(pr({ mergeable: false }), { now }).action, "explain");
  assert.equal(decide(pr({ mergeable: false, explained: true }), { now }).action, "skip");
});

test("drafts and forks are not acted on", () => {
  assert.equal(decide(pr({ draft: true }), { now }).action, "skip");
  assert.equal(decide(pr({ sameRepository: false }), { now }).action, "skip");
});

test("the explanation carries the marker that keeps it from being posted twice", () => {
  const body = explanation("main");
  assert.ok(body.startsWith(COMMENT_MARKER));
  assert.match(body, /conflicts with `main`/);
});
