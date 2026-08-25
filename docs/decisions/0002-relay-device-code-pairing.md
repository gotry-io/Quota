# ADR 0002: Relay device-code pairing

- Status: Superseded by [ADR 0006](./0006-managed-account-device-usage.md) on 2026-08-10
- Date: 2026-08-02

QuotaCLI paired a machine with a Relay through an OAuth-style device-code flow: `quotacli relay
pair [--relay <url>]` opened an unauthenticated pairing session, Relay minted a secret device code
and a separate human-readable user code, the operator approved that user code in a QuotaBar holding
an anonymous owner capability, and Relay returned a `quota:write:self` bearer once and kept only its
hash. Codes were single-use, expired within ten minutes, and were rate-limited; the paired device
could revoke only itself, and QuotaBar could revoke devices in its own group. Pairing ended with one
foreground collection and upload so the device appeared as reporting immediately; recurring uploads
belonged to the host, meaning QuotaBar's five-minute app-lifetime scheduler on macOS and an
operator-owned scheduler elsewhere.

It was replaced because [ADR 0006](./0006-managed-account-device-usage.md) put a real signed-in
Account behind device authorization, which makes a device code an authorization step against an
identity rather than a way to conjure an anonymous owner group.
