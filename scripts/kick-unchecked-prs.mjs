#!/usr/bin/env node
// A pull request whose checks never started, and what to do about it.
//
// GitHub starts no `pull_request` workflow for a pull request it cannot merge: with a conflict there
// is no merge ref to check out. The conflict can then disappear without a push to the pull request —
// main moves, and the lines that collided are gone — and nothing starts the workflows that were
// never started, because a base branch moving is not a `pull_request` event. The pull request sits
// with no check at all, auto-merge armed and waiting for a required check that will never report.
// #277 waited ninety minutes that way before a person closed and reopened it.
//
// This decides, for each open pull request, whether to start `ci` on its branch by
// `workflow_dispatch` — one of the two events `GITHUB_TOKEN` is allowed to raise — so the required
// checks report on the same head commit. It touches neither the branch nor the pull request.
//
// Usage: kick-unchecked-prs.mjs [--dry-run] [--min-age-minutes 10]
//   reads the repository from GITHUB_REPOSITORY and calls `gh`.
import { execFileSync } from "node:child_process";

export const COMMENT_MARKER = "<!-- quota:unchecked-pr-conflict -->";

/**
 * What to do with one pull request.
 *
 * - `skip`: not ours to act on, or nothing is wrong.
 * - `wait`: too young to judge. Check runs take a minute to register after a pull request opens,
 *   and "no checks yet" read at that moment is how a healthy pull request gets kicked.
 * - `dispatch`: mergeable, old enough, and its head commit has no check run — start `ci`.
 * - `explain`: still in conflict, so dispatching would only test a branch that cannot merge; say
 *   once why nothing is running.
 */
export function decide(pr, { now, minimumAgeMinutes = 10 }) {
  if (pr.draft) return { action: "skip", why: "draft" };
  if (!pr.sameRepository) return { action: "skip", why: "fork: its workflows need a maintainer" };
  if (pr.checkRuns > 0) return { action: "skip", why: "checks exist" };
  const ageMinutes = (now - Date.parse(pr.createdAt)) / 60_000;
  if (!(ageMinutes >= minimumAgeMinutes)) {
    return { action: "wait", why: `opened ${Math.max(0, Math.floor(ageMinutes))} min ago` };
  }
  // GitHub computes mergeability lazily; `null` means "not computed yet", which is not a verdict.
  if (pr.mergeable === null || pr.mergeable === undefined) {
    return { action: "wait", why: "mergeability not computed yet" };
  }
  if (pr.mergeable === false) {
    return pr.explained
      ? { action: "skip", why: "in conflict, already explained" }
      : { action: "explain", why: "in conflict with its base" };
  }
  return { action: "dispatch", why: "mergeable with no check run on its head commit" };
}

export function explanation(base) {
  return [
    COMMENT_MARKER,
    `No check has run on this pull request because it conflicts with \`${base}\`: GitHub starts no`,
    "`pull_request` workflow for a pull request it cannot merge. Resolve the conflict and push —",
    "that push starts the checks. If the conflict clears by itself because the base moved,",
    "`kick-unchecked-prs` starts `ci` on this branch the next time the base moves.",
  ].join("\n");
}

function gh(args, { input } = {}) {
  return execFileSync("gh", args, { encoding: "utf8", input, maxBuffer: 64 * 1024 * 1024 });
}

function main() {
  const argv = process.argv.slice(2);
  const dryRun = argv.includes("--dry-run");
  const ageIndex = argv.indexOf("--min-age-minutes");
  const minimumAgeMinutes = ageIndex === -1 ? 10 : Number(argv[ageIndex + 1]);
  if (!Number.isFinite(minimumAgeMinutes) || minimumAgeMinutes < 0) {
    console.error("--min-age-minutes takes a non-negative number");
    process.exit(2);
  }
  const repository = process.env.GITHUB_REPOSITORY;
  if (!repository) {
    console.error("GITHUB_REPOSITORY is not set");
    process.exit(2);
  }

  const listed = JSON.parse(
    gh(["api", `repos/${repository}/pulls?state=open&per_page=100`, "--paginate", "--slurp"]),
  ).flat();
  const now = Date.now();
  let acted = 0;
  for (const item of listed) {
    // The list endpoint never carries `mergeable`; the single-pull endpoint computes it.
    const one = JSON.parse(gh(["api", `repos/${repository}/pulls/${item.number}`]));
    const runs = JSON.parse(
      gh(["api", `repos/${repository}/commits/${one.head.sha}/check-runs?per_page=1`]),
    );
    const comments = JSON.parse(
      gh(["api", `repos/${repository}/issues/${one.number}/comments?per_page=100`]),
    );
    const pr = {
      number: one.number,
      draft: one.draft,
      sameRepository: one.head.repo?.full_name === one.base.repo.full_name,
      createdAt: one.created_at,
      mergeable: one.mergeable,
      checkRuns: runs.total_count,
      explained: comments.some((comment) => (comment.body ?? "").includes(COMMENT_MARKER)),
    };
    const verdict = decide(pr, { now, minimumAgeMinutes });
    console.log(`#${pr.number} ${one.head.ref}: ${verdict.action} — ${verdict.why}`);
    if (dryRun || verdict.action === "skip" || verdict.action === "wait") continue;
    acted += 1;
    if (verdict.action === "dispatch") {
      try {
        gh(["workflow", "run", "ci.yml", "--repo", repository, "--ref", one.head.ref]);
      } catch (error) {
        // The workflow file is read from the branch being dispatched, and a branch cut before `ci`
        // accepted `workflow_dispatch` refuses it. Updating that branch from main fixes both.
        console.log(
          `::warning::#${pr.number}: could not start ci on ${one.head.ref} ` +
            `(${
              String(error.stderr ?? error.message)
                .trim()
                .split("\n")[0]
            }); ` +
            "update the branch from main.",
        );
      }
    } else if (verdict.action === "explain") {
      gh(
        [
          "api",
          `repos/${repository}/issues/${pr.number}/comments`,
          "--method",
          "POST",
          "--input",
          "-",
        ],
        { input: JSON.stringify({ body: explanation(one.base.ref) }) },
      );
    }
  }
  console.log(`${acted} pull request(s) acted on${dryRun ? " (dry run: none)" : ""}.`);
}

if (import.meta.url === `file://${process.argv[1]}`) main();
