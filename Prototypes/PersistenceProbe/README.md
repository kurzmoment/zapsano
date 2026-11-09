# SwiftData persistence probe

An isolated experiment, not the production persistence layer. Requires macOS 15+.

Run from this directory:

```sh
swift test --scratch-path /tmp/faktura-persistence-probe-build
```

Verified locally on 2026-10-30 with Xcode 26.2 and Swift 6.2.3: all five Swift Testing tests passed.

The tests exercise real disk-backed SwiftData stores:

- Decimal values persisted as normalized decimal strings survive closing and reopening the store exactly for the supplied samples.
- Invoice numbering and sequence advancement are saved together and survive reopening.
- A repeated issue request is rejected, including after reopening.
- An injected failure immediately before saving rolls both pending changes back; retry uses the original next number.
- Structured JSON backup restores drafts, issued invoices, amounts and sequence into a separate empty store; invalid sequence data is rejected before mutation.

The experiment uses one `@MainActor` owner, disables autosave and does not suspend inside a mutation. It does not establish safety for independent writer contexts or multiple processes. Production callers must share a mutation owner, or use a separately verified coordination strategy.

## Limits and remaining gates

The failure injection is **before** `save()`: it does not simulate a disk-full error during a database commit, abrupt process termination, or power failure. Migration across schema versions, archive/PDF consistency, atomic replacement of the active store, PDF checksums, and background rendering are not tested here. Backup is deliberately JSON data only, without PDF files.

Restoring an older backup cannot prove that the next number has not already been used in documents issued after that backup. Production recovery needs an explicit reconciliation workflow before issuing further invoices.

Invoice numbers are deliberately simple integers in this experiment. User-selected formatting, year rollover, VAT rules, rounding policy, and business validation belong to separate work. The entity scan used here is suitable only for the tiny probe dataset, not production invoice lookup.

These results support proceeding with further SwiftData validation; they are not approval of all milestone-0 durability requirements.
