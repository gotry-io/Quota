# ADR 0008: Complete local data and unified diagnostics

- Status: Superseded by [ADR 0022](./0022-minimal-diagnostics.md) on 2026-08-25
- Date: 2026-08-11

Provider and agent output was untrusted input, but no valid fact was to be lost because a
neighbouring one was invalid: a malformed record was isolated to that record, an unreadable file to
that file, and a failed provider never discarded another provider's quota. Model identifiers stayed
opaque bounded provider text that needed no catalog price to be retained, a zero-value record was
counted rather than kept, and an upload was partitioned losslessly on the smallest complete time unit
the replacement contract allowed — a partition that could not be represented stayed pending and
visible instead of being dropped. The service was the only diagnostic authority: `diagnose` returned
a bounded `schema_version: 2` report with three independent summary axes (`operation`, `data`,
`attention`), four fixed surfaces, up to 128 checks and 256 findings with bounded metrics, evaluated
only at a completed refresh boundary, and QuotaBar and QuotaCLI rendered it rather than inspecting
SQLite. Absent optional setup was inactive rather than broken, an Account reading could satisfy
Overview without excusing a local source this device could not collect, and names, codes, and
subjects were control-free: provider and agent ids only, never paths, filenames, model lists,
prompts, completions, session or device identifiers, credentials, or parser excerpts. QuotaCLI exited
zero for healthy operation with current or empty data and no required attention.

It was replaced because reporting one failure as a check, a finding, an impact, a severity, an
occurrence count, and a recovery verb said the same thing six times without once carrying the
sentence a person reads — [ADR 0022](./0022-minimal-diagnostics.md) keeps the surfaces, the
redaction rules, and the exit rule, and replaces the rest with one message the service writes.
