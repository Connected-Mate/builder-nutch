# Saved token history

Builder Nutch keeps the token activity it has observed independently of Claude Code and Codex session files. The Usage timeline reads this saved history. Removing an original session or clearing the read cache does not remove recorded tokens.

## Recording

The running app records at launch, every minute, on wake and when account profiles change. Opening Usage or refreshing also records a reading. One shared collector serves the window and background work; reads are bounded so the notch stays responsive. The collector discovers newly added profiles on later passes and scans available historical files without restricting retention to the selected 7- or 30-day view.

Only locally available telemetry can be recorded. Files deleted before Builder Nutch ever reads them cannot be reconstructed. Partial scans and fields the assistant did not report remain identified as incomplete. Recording stops when Builder Nutch quits.

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
