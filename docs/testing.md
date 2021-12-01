# Verification

The acceptance boundary is executable behavior. A successful build, a rendered
report, or a passing example is not enough to establish archive correctness.
The verification stack therefore combines known answers, independent arithmetic,
property campaigns, real filesystem operations, subprocess crashes, and an
independent archive reader.

## Entry points

```sh
make verify
make acceptance
make verify-evidence
make replay-evidence
```

`verify` runs fresh behavior checks and writes ephemeral evidence under
`build/evidence/`. `acceptance` runs the same checks, then freezes the successful
artifacts under `evidence/local/`. `verify-evidence` performs validation only;
it does not regenerate missing or stale evidence. `replay-evidence` validates
the saved binding, then independently decodes its retained synthetic archive.

## Unit and integration suites

The same suite entry point is compiled in checked debug and checked release
mode. Raw logs are captured without hiding the child process's exit status.

| Area | Checks |
|---|---|
| Binary codec | Full-width integers, zero-length fields, every primitive truncation, oversized allocation lengths |
| SHA-256 | FIPS known answers, million-byte vector, incremental/padding boundaries, domain separation |
| CRC32C | Standard Castagnoli known answers |
| GF(256) | All 65,536 products against polynomial multiplication, every inverse, repeated powers |
| Matrix inversion | Pivot swaps, both inverse products, singular/ragged/nonsquare rejection, input preservation |
| Erasure coding | Every sufficient subset for small geometries, randomized geometries and order, duplicates, padding |
| Chunking | Read-buffer partition invariance, prefix insertion reuse, repeated bytes, min/max constraints |
| Compression | Token boundaries, random binary round trips, truncations, expansion bounds |
| Capsules | Raw/compressed recovery, every header byte corruption, payload changes, mixed identities, surplus equations |
| Metadata | Canonical encoding, unknown/duplicate keys, integer types, deep JSON, invalid UTF-8, tree structure |
| Paths and links | Traversal, internal symlinks, parent escape through chains, cycles, literal UTF-8 preservation |
| Filesystem I/O | Immutable publication, explicit replacement, no-follow reads, output cleanup |
| Locking | Multiple readers, writer exclusion, exception release, permanent inode |
| Acquisition | Empty trees/files, links, source replacement, nested repository rejection |
| Restore | Two lost volumes, byte and metadata checks, failed-output isolation, existing destination rejection |
| Damage | Shared-chunk impact, simulated loss, honest logical-byte accounting |
| Repair | Missing/corrupt packets, stale whole-plan rejection, budgets, plan edits |
| Planner | Randomized cases against exhaustive subset selection, budget exhaustion, infeasibility |
| Salvage | Offset-accurate fragments, missing ranges, complete-file verification |
| Maintenance | Shared reachability, stale GC plans, missing-volume refusal, edited deletion lists |
| Transport | Complete import/export, truncation, payload corruption, transcript omission/reordering |
| Rescue | Detached volumes, renamed packets, missing roots, insufficient media, foreign-volume rejection |
| Reporting | HTML escaping, offline policy, complete versus incomplete accounting |

See the current saved logs for the exact suite count. Counts are derived from
executed `[OK]` records rather than a manually maintained README badge.

## Deterministic randomized campaigns

`tests/campaign.nim` executes the following fixed workload with seed
`ca17ca17`:

| Campaign | Actual cases required |
|---|---:|
| Arbitrary sufficient-shard recovery | 3,000 |
| Compression round trips | 10,000 |
| Arbitrary compressed-input parsing | 10,000 |
| Single-bit packet corruption | 5,000 |
| Arbitrary packet parsing | 10,000 |
| Canonical manifest mutation | 10,000 |

Accepted metadata mutations are allowed only when the result is itself a valid
canonical manifest. For example, changing one permitted label byte can produce
a different valid manifest. The campaign records that count rather than
pretending every mutation must be rejected.

The campaign emits executed case counts, payload bytes, and CPU time as JSON.
Evidence validation requires the declared workload exactly. A slower phase or a
failure is not handled by reducing its case count.

## Real-process acceptance

`tools/verify.py` drives the compiled CLI against synthetic real directories.
It captures every command's stdout, stderr, return code, and hashes.

The command surface covers acquisition, snapshot navigation, deep checks,
targeted extraction, restore, statistics, weighted media choice, correlated loss
envelopes, report generation, portable transport, repair, retention, forgetting,
collection, index-free discovery, lost-root recovery, and detached assembly.

Physical-damage acceptance enumerates all 22 zero-, one-, and two-volume loss
subsets for a default 4+2 archive. Every recoverable case restores files and
passes the independent reader. Additional cases corrupt packets, exceed the
erasure budget for one shared object, salvage surviving ranges, reject stale
plans, and verify bounded repair exit statuses.

The file-size regression imposes a real 64 KiB `RLIMIT_FSIZE` while ignoring
`SIGXFSZ`, so destination writes return an I/O error. It requires a nonzero
status and no published salvage destination. FIFOs are also tested through a
real process with a timeout, ensuring source validation does not block reading
a special file.

## Actual crash boundaries

The environment hook `CAIRN_CRASH_AT` sends `SIGKILL` to the running process at
one named boundary. It does not throw a catchable exception or run cleanup.
Do not set this variable during ordinary operation.

| Operation | Boundaries exercised |
|---|---|
| Backup | file written; file synced; name published; directory synced; one object packet; complete object; source revalidated; manifest stored; first root published |
| Restore | complete private tree synced; final tree published |
| Repair | one replacement packet committed |
| Forget | one root copy removed |
| GC | one unreachable packet removed |

There are 14 executed crash cases. Each is followed by a fresh process. Existing
snapshots remain checkable, visible new snapshots have complete file graphs,
locks are released, and maintenance can continue with a fresh plan.

These are process-crash checks on real filesystems. They do not establish
power-loss durability, controller behavior, device atomicity, or a filesystem's
response to sudden hardware removal.

## Independent reader

`tools/oracle.py` uses only Python's standard library. It does not call Cairn,
import generated Nim code, or use Nim's arithmetic routines. It implements:

- Polynomial GF multiplication and independent matrix inversion
- Its own systematic generator construction and shard reconstruction
- A separate binary packet reader and CRC32C
- `hashlib` object and file identities
- A separate bounded run decoder
- The documented SplitMix64 gear table and normalized chunk-boundary rules
- Root agreement, directory-parent checks, file assembly, and restored-byte checks

For the initial healthy fixture it enumerates every sufficient shard subset.
Every media-loss case independently decodes its surviving graph. Raw oracle
reports are retained and their counts are derived during evidence validation.

An algebraic negative control modifies a parity payload and recomputes both
its shard hash and header CRC. Packet-local checks therefore pass by design.
The complete-capsule equation check and exhaustive independent reader must both
reject the inconsistency. This protects against a shallow verifier that only
checks local checksums.

## Source binding and replay

Before real-process acceptance starts, a SHA-256 manifest covers source,
configuration, documentation, examples, and verification tooling. Generated
build outputs, Git data, compiler archives, and the evidence directory are
excluded. The exact same source manifest must still hold when acceptance ends.

Frozen artifacts include:

- Source manifest and acceptance receipt
- Debug and release suite logs
- Randomized campaign JSON
- Compiler, C compiler, Python, and platform information
- Raw CLI stdout/stderr and command metadata
- Raw independent-reader reports
- A synthetic archive fixture containing both acquired snapshots
- Per-artifact SHA-256 binding

`verify-evidence` checks source bytes, artifact hashes, raw command hashes,
executed command and SIGKILL counts, independent-decoder totals, workload
counts, and debug/release suite agreement. It fails on missing or stale inputs.

`replay-evidence` extracts only validated regular-file/directory fixture members
into a temporary directory and reconstructs its snapshots with the independent
reader across all sufficient shard subsets.

After freezing, `tools/test_evidence.py` runs eight rejection controls against
private copies: changed source, edited artifacts, missing raw logs, false
rechecksummed counts, reduced workloads, edited raw outputs, altered crash
statuses, and disagreeing debug/release logs. Updating an outer artifact hash
must not conceal an inconsistent inner record.

This is a reproducible integrity receipt, not a signed third-party attestation.
A malicious party able to rewrite all source and evidence can construct a new
receipt. The purpose is to make stale, missing, edited, or unsupported local
claims detectable and the retained dataset independently inspectable.

## Platform checks

CI builds and runs verification on Linux and macOS. A separate Clang sanitizer
job exercises AddressSanitizer and UndefinedBehaviorSanitizer. Hosted results
belong to their exact commit; consult the Actions run rather than inferring
current status from an old local receipt.

## Limits of the evidence

The suite does not prove absence of bugs. It does not test every filesystem,
permission configuration, hardware controller, storage device, compiler release,
or adversarial local race. Production guarantees are bounded by the format,
threat model, stated resource limits, and the actual executed checks.

Every observed behavioral defect during implementation is recorded in
[bugs.md](bugs.md), including its failing reproducer and retained regression.
