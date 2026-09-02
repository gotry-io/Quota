# ADR 0030: A rotation whose successor was never presented did not happen

- Status: Accepted
- Date: 2026-09-02
- Extends [ADR 0027](0027-one-token-per-client.md)

## Context

`D1AccountState.refreshSession` rotated the family with a compare-and-swap `UPDATE` and then read
the row back with a separate `authorizeSession` `SELECT` plus an `UPDATE last_used_at` batch.
Anything that failed after the `UPDATE` committed left the client holding the token it just spent.
Its next refresh matched 0 rows, Relay answered `invalid_grant`, and QuotaBar cleared the session
and showed signed out.

On 2026-09-01T19:04:46Z the read-back was D1 refusing the query under the free-tier daily row
budget; other days it was a client timeout. In production, 7 of the 10 QuotaBar sessions issued
since 2026-08-27 ended exactly this way: their `last_used_at` equals `expires_at − 15 min` to the
millisecond, i.e. the rotated successor was never presented. Each device rotates about four times
an hour, so a lost rotation answer is the dominant sign-out cause.

## Decision

**A rotation whose successor was never presented did not happen from the client's point of view.**
The row remembers the refresh token it replaced and when. While the successor is unspent
(`last_used_at = rotated_at`), the replaced token is accepted wherever the current one is: a
refresh with it rotates the family again (the unspent successor dies), a revoke with it ends the
family. Once the successor has been spent, the replaced token is dead for every purpose. No time
bound: the predicate is "unspent", so a Mac that slept right after a lost answer still recovers
hours later. Rotation returns its principal from `UPDATE … RETURNING`; there is no read after the
write.

## Consequences

There is no time bound on the replaced token, only the unspent predicate, so a device that comes
back much later still recovers if it never presented the successor. Two concurrent refreshes with
one token remain a client defect and the later one wins, the same outcome as before with the roles
reversed: the first rotation's successor is unspent, so the second refresh spends the replaced
token and that successor dies. The replaced token dies the moment the successor is spent, for
refresh and for revoke.
