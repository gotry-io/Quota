# ADR 0060: Freeze new providers and keep two provider tiers

- Status: Accepted
- Date: 2026-09-21

## Context

Twelve providers have a collector, a catalog row, and a `docs/providers/<id>.md` strategy file, and
the count has only gone up. The twelfth cost as much to add as the second and is read by fewer
people, while what the earlier ones actually prove has never been written down anywhere a reader
can check. `packages/provider/fixtures/quota-responses.json` records seven provider response
bodies and exactly one of them is read by a test; the other six assert nothing, and nobody could
have known that from the catalog, the strategy files, or the generated reference. Most collectors
are covered instead by unit tests holding a response inline, which is real coverage that no
document names. So a reader asking "can Quota tell me my weekly Cursor quota, and how do you know"
had no answer, and a thirteenth provider would have made the question worse rather than better.

Quota's own readers are overwhelmingly on Codex and Claude Code. Those two are also the only
providers with an official credential rung, a browser rung, an iOS collector, a local Usage parser,
and a shared conformance fixture both runtimes answer. Treating them like the ninth API-key gateway
spends the same review on very different value.

## Decision

**No new provider is added for one cycle.** The cycle ends at the next planning round — the round
that follows the one this ADR was written in — not on a date. Widening the catalog is the thing
being paused; a fix, a fixture, a new window, or a removed rung on one of the twelve is ordinary
work and is not frozen. A request for a thirteenth provider is answered with this ADR and the
capability matrix, and reconsidered when the cycle closes.

**There are two tiers, and the catalog states which.** Each provider carries
`capabilities.tier` in `packages/provider/catalog.json`:

- **`first_class` — Codex and Claude Code.** Every capability they have is validated, by a fixture,
  a named test, or a real account, and a regression in one blocks a release. What is not yet
  validated is not an exemption: it is named, one key at a time, in that provider's
  `capabilities.known_gaps`, and the generator refuses an unverified cell the list does not name
  and a listed key that is no longer unverified. The gap can therefore only shrink, and the list
  cannot go stale.
- **`best_effort` — the other ten.** They are collected, uploaded, and priced on the same code
  paths, and the matrix says exactly which of their capabilities anything proves. A best-effort
  capability that breaks is a defect to fix; it does not hold a release. They carry no
  `known_gaps`: the matrix's Unverified table already says everything.

**The matrix is generated, and its provenance is checkable.** Each provider's
`capabilities.validated` map names one entry per capability Quota has for it, and each entry says
how that capability was validated: `fixture` with a repository path and, for JSON, the pointer
inside it; `test` with the file and the one test function that asserts it; `live` with the date a
real account answered; or `unverified`. A capability absent from the map is one Quota does not have.
`scripts/generate-capability-matrix.mjs` renders `docs/providers/README.md` from that block and its
`--check` mode refuses a stale one: a fixture path that is not a file, a JSON pointer that resolves
to nothing, a named function the file does not define exactly once or defines without a test
attribute, a live date that has not happened, a `known_gaps` list that does not match the
unverified cells, or a `channel.api_key`, `channel.browser_session_macos`, `account.sync`, or
`status.statuspage_v2` claim that disagrees with the catalog field which already decides it. So
evidence someone moves, renames, or unmarks cannot leave a claim about it standing.

`fixture` and `test` are both real evidence and the matrix keeps them apart on purpose: a recorded
fixture is a provider response this repository can replay and several runtimes can answer, while a
test holding its response inline proves the mapping and nothing beyond that file. Moving a claim
from `test` to `fixture` is a real improvement, not bookkeeping.

`unverified` is a statement about this repository, not about the collector. It means the reading
may well be right and nothing here says so.

## Consequences

`docs/providers/README.md` is generated and is the directory index for the strategy files;
`pnpm check:capability-matrix` joins the other generated-artifact checks in `package.json`, the
pre-commit hook, and `verify-web`. Adding a provider now also means adding its `capabilities`
block, which the catalog schema requires, so a thirteenth provider cannot arrive without saying
what it can do and what proves it. `CONTRIBUTING.md` points a would-be contributor here.

**First-class is not yet true, and here is the gap.** Codex has none: its eleven capabilities are
seven fixture, three test, and one live. Claude Code has one, and it is
`capabilities.known_gaps: ["pricing.api_equivalent"]` — nothing in this repository prices an
`anthropic_direct` Claude row, so the claim that Quota can put an API-equivalent cost on Claude Code
Usage rests on the pricing engine being provider-agnostic rather than on any statement about Claude.
Closing it means a `pricing-conformance.json` row whose agent is `claude_code`, the way
`unknown_channel_grok` already does for Grok. Until that lands, "first-class" describes the
standard those two are held to, not a property they both have.

Three claims that are `test` rather than `fixture` are the next thing to raise, because a fixture is
what more than one runtime can answer: Codex's monthly classification and its Balance and Reset
Credits windows, and Claude's Extra Usage cap. The six dead entries in `quota-responses.json` are
the cheapest work in the file — DeepSeek, Kimi Code, and LiteLLM are covered today by unit tests
holding their own inline copies of responses the fixture already records, so a test that reads the
recorded one instead would delete a duplicate and raise three cells at once.
