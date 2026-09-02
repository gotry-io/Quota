# ADR 0029: Official price for an unnamed billing channel

- Status: Accepted
- Date: 2026-09-01
- Extends [ADR 0009](0009-versioned-model-catalog.md): report-time valuation does not rewrite facts

## Context

Usage cost is a valuation at official API prices. A priced row is what the catalog would charge for
those tokens on that day, not what the collector guessed the user was billed. Source-reported cost
is the fallback when the catalog cannot name a price, not the primary figure.

Commit 44ac088 fixed the collection rule "never infer a channel from model text." A collector that
does not see a provider id stores `billing_channel: unknown` and `channel_source: unknown`. That is
the fact: the source did not name who was paid. Gateways that merely proxy a vendor stay unknown
too. The rule belongs on facts and stays there.

Those two met at `resolve_pricing_entry`. An unknown channel returned `unknown_channel` before the
catalog was asked, so a row whose model is only sold by one vendor — Grok on xAI, Kimi K2.5 on
Moonshot — stayed unpriced even though the official rate was in the catalog. Account summaries then
showed a hole, or a source-reported remainder, for usage whose vendor was obvious from the model
name the fact already carried.

## Decision

**The pricing layer values an unnamed-channel row at the vendor's official direct price when exact
model or alias matching lands in exactly one vendor-direct channel.** Vendor-direct means the
vendor's own billed channel (`openai_direct`, `anthropic_direct`, `xai_direct`, `moonshot_direct`,
`deepseek_direct`). Gateways — OpenRouter, Bedrock, Vertex, Azure OpenAI, and any other proxy — are
never candidates. A successful match records `vendor_official_price` so the valuation is auditable.
`agent_default_channel` is not added: the fact's `channel_source` is `unknown`, not `agent_default`.

**Ambiguity and absence stay unpriced, and they say why.** Candidates in more than one vendor-direct
channel remain `unknown_channel`; only a named channel could disambiguate. No vendor-direct match
reports `unknown_model`, which is the actionable signal — the catalog has no official price for that
name. Date and dimension matching then run against that single channel as they do for a named one.

**Facts are never rewritten, and collectors never infer.** The stored row keeps `unknown`. The
channel used to price it exists only in the cost outcome. Collection, uploads, and D1 stay on the
44ac088 rule.

## Consequences

The unpriced remainder shrinks to rows that are genuinely unattributable — two vendors could have
sold that name — or uncataloged, including subscription endpoints with no official per-token price.
The assumption keeps the valuation distinct from a source that named the channel. Rust and Relay
share the same resolution, so This Mac and Account still agree on the same fact.
