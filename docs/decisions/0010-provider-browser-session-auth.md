# ADR 0010: Provider browser-session authentication

## Status

Accepted

## Context

Some providers expose account quota only through an authenticated browser session. Quota needs a
macOS acquisition path without moving credential validation, persistence, or provider networking
out of the Rust service. The released managed Account/Relay v2 protocol also has a closed provider
enum that cannot accept new local providers without a new protocol version.

## Decision

Declare browser-session acquisition and managed-account synchronization independently in the
[provider catalog](../../packages/provider/catalog.json). QuotaBar uses the declared allowlist to
read only matching cookie records into bounded Swift memory and sends one minimal candidate at a
time over private child stdin; Rust revalidates the catalog rules, verifies the provider account,
performs provider networking, and stores the session in the owner-only local SQLite state. Cursor is
the first adapter and remains local-only because `account_sync` is false, preserving the released v2
network enum.

The credential and redaction boundary is specified in [security](../security.md), and provider API
behavior remains in [provider collection](../provider-collection.md).

## Consequences

Browser/profile discovery can later move to Rust without changing authentication authority or
persistence. Browser cookies never enter Relay or managed-account payloads. Adding a provider to the
local catalog does not automatically make it network-compatible; managed synchronization requires
an explicit protocol-compatible catalog decision.
