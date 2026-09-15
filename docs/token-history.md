# Saved token history

Builder Nutch keeps the token activity it has observed independently of Claude Code and Codex session files. The Usage timeline reads this saved history. Removing an original session or clearing the read cache does not remove recorded tokens.

## Recording

The running app records at launch, every minute, on wake and when account profiles change. Opening Usage or refreshing also records a reading. One shared collector serves the window and background work; reads are bounded so the notch stays responsive. The collector discovers newly added profiles on later passes and scans available historical files without restricting retention to the selected 7- or 30-day view.

Only locally available telemetry can be recorded. Files deleted before Builder Nutch ever reads them cannot be reconstructed. Partial scans and fields the assistant did not report remain identified as incomplete. Recording stops when Builder Nutch quits.

Claude Code projects and Codex active and archived sessions are read. Input, output, cache creation/read and reasoning are kept when reported by the assistant. Cache counts are included in input; reasoning is a subset of output and is never added to the total a second time. Missing fields remain unavailable, rather than becoming invented measurements.

## Consumption stamps

Usage has a small Stamps disclosure for cumulative consumption. Eight levels correspond to 100,000; 1 million; 10 million; 100 million; 1 billion; 10 billion; 100 billion; and 1 trillion recorded tokens. The next threshold and collection of reached/locked stamps stay inside the same screen.

Progress is derived from all saved history, independently of the 7- or 30-day chart. Changing periods or deleting source sessions does not reset it. Stamps represent recorded tokens, not skill, monetary cost or remaining subscription allowance. Correcting a proven counting error also corrects the associated progress. An achievement date is shown only when the saved timing establishes when the threshold was crossed; old totals with incomplete timing still count without an invented date.

## Storage and migration

The private archive lives at:

```
~/Library/Application Support/Codenotch Accounts/history/token-history-v1.json
```

It stores numeric token events, timestamps, provider/session/request identifiers, project associations and reading coverage. Saved history is independent of the disposable index at `insights/usage-ledger.json`. Available version-5 index totals are preserved during the first migration, before any missing source entries can be pruned. These older minute-level totals remain a floor until individual records can be reconciled.

Repeated readings, restored files and copies are reconciled by recorded identity. New activity extends the archive. Provider records that lack an identifier use a timestamp-and-metadata fingerprint; records that are indistinguishable in the original telemetry cannot be proven to be separate requests.

Writes use private permissions, an integrity check, an atomic replacement and a cross-process lock. A persistence failure is shown in Usage; it is not reported as a successful backup, and a corrupt archive is preserved for recovery. No automatic age-based purge is applied to saved history.

## Backup and recovery

This is a local archive, not synchronization between Macs. A full Mac erase also removes it unless another backup exists. To keep an external copy, quit Builder Nutch and copy the `history` directory using your usual backup tool. Keep that directory separate from session-cleaning rules.

To restore the same archive on this Mac, quit Builder Nutch, preserve any current `history` directory, and restore the backed-up directory in the location above. Do not edit numeric records or the integrity information by hand. Subsequent readings reconcile retained source files against the saved identities.
