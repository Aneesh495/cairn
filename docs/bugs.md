# Regression ledger

Each entry records an observed behavioral defect, its failing reproduction,
the correction, and a permanent test. Compiler diagnostics during development
are not counted as behavioral regressions.

## B001: system symlink above a selected archive root

- Reproduction: `make test`, `portable archive paths / managed paths reject existing symlink ancestors`
- Observed failure: `symlink in managed path: /var` on macOS temporary directories
- Cause: managed-path validation rejected a system link above the caller's selected root
- Correction: canonicalize that root once, then reject links in every relative component below it
- Permanent check: `tests/test_paths.nim`, with both a real child and an internal symlink child

## B002: low-level publication accepted an incomplete content graph

- Reproduction: `make test`, `replicated snapshot roots / publishing an incomplete content graph must fail`
- Observed failure: the expected exception was absent; a root named missing file content
- Cause: publication validated the manifest schema without validating its chunk dependencies
- Correction: reconstruct every referenced chunk, verify lengths, and recompute each file digest before publishing a root
- Permanent check: `tests/test_references.nim`; the same fixture must fail before its data capsule is stored

## B003: chained symbolic links defeated lexical confinement

- Reproduction: `make test`, `strict snapshot manifests / symbolic link chains cannot escape through an intermediate parent`
- Observed failure: the manifest containing `link -> sub/up/..` and `sub/up -> ..` was accepted
- Cause: each target stayed inside the tree when checked lexically, but actual chained resolution escaped
- Correction: resolve the complete manifest link graph with POSIX parent semantics and a 40-link bound
- Permanent checks: chained parent escape and cyclic links in `tests/test_manifest.nim`

## B004: one damaged volume identity blocked all healthy volumes

- Reproduction: `make test`, `content capsule storage / damaged volume metadata is an erasure, not an archive-wide failure`
- Observed failure: malformed `volume.json` raised before a readable capsule could use the other five volumes
- Cause: volume identity decoding and foreign-volume detection shared the same unconditional failure path
- Correction: unreadable identity metadata makes that volume unavailable; valid foreign identities still fail closed; explicit repair can recreate damaged identity metadata
- Permanent check: `tests/test_store.nim`, including successful reconstruction and identity repair

## B005: salvage misclassified destination I/O failures as source damage

- Reproduction: `python3 tools/regression_io.py`, using a real 64 KiB `RLIMIT_FSIZE` and ignored `SIGXFSZ`
- Observed failure: exit status 0 and a published salvage directory after fragment writes returned `EFBIG`
- Cause: the source-recovery exception handler also surrounded destination writes
- Correction: classify only archive reads inside that handler; destination publication failures now unwind the private tree
- Permanent check: `tools/regression_io.py`, requiring a nonzero status and no published destination

## B006: out-of-range filesystem timestamps raised an arithmetic defect

- Reproduction: `make test`, `filesystem metadata range checks / filesystem timestamps beyond the int64 nanosecond range reject safely`
- Observed failure: `OverflowDefect` while converting a year beyond the nanosecond representation
- Cause: raw `stat` seconds were multiplied before range validation
- Correction: validate the timespec fraction and use the checked time conversion for both mtime and ctime
- Permanent check: `tests/test_fsmeta.nim` with a 20-billion-second timestamp

## B007: surplus parity was not checked against decoded content

- Reproduction: `make test`, `self-describing recovery capsules / surplus parity must agree with the recovered data`
- Observed failure: a modified parity shard with recomputed packet checksums was accepted when the first k data shards were intact
- Cause: decoding consumed k shards and checked the object digest but did not check surplus coding equations
- Correction: re-encode the recovered encoded bytes and compare every supplied shard
- Permanent check: `tests/test_capsule.nim`; this is an algebraic negative control beyond ordinary bit-corruption checks

## B008: a budget-limited repair exited with complete-success status

- Reproduction: remove a volume, then run `cairn repair REPO LABEL --max-packets 0 --apply`
- Observed failure: status 0 despite nonzero `deferred_packets`
- Cause: the CLI reported plan application without reflecting the plan's remaining damage
- Correction: bounded repairs with deferred packets return 4; plans containing lost objects return 3; saved-plan application reports the same fields
- Permanent check: the bounded-repair negative control in `tools/verify.py`

## B009: low-level path helpers accepted invalid shard positions

- Reproduction: `make test`, `repository creation and volume identity / all lookup helpers reject positions outside configured volumes`
- Observed failure: negative and out-of-range positions produced managed paths instead of rejecting
- Cause: packet/reference path helpers checked IDs and labels but relied on callers to check the position
- Correction: validate both position bounds at each public path helper and repair application boundary
- Permanent check: `tests/test_repository.nim` for both helper families and both invalid bounds

## B010: the standard timestamp setter truncated stored nanoseconds

- Reproduction: `make test`, `filesystem metadata range checks / restored modification time preserves sub-microsecond precision`
- Observed failure: stored `1700000000123456789` became `1700000000123456000`
- Cause: Nim's standard POSIX setter calls `utimes`, which accepts only microseconds
- Correction: use descriptor-based `futimens`, preserve atime with `UTIME_OMIT`, and read back exact mode/mtime before publication
- Permanent checks: `tests/test_fsmeta.nim`, every regular-file/directory timestamp in `tests/test_restore.nim`, and independent Python restored-mtime checks

## B011: conservative time guards rejected valid int64 endpoints

- Reproduction: `make test`, `filesystem metadata range checks / the complete representable int64 nanosecond domain round trips`
- Observed failure: valid minimum and maximum nanosecond values raised a range error
- Cause: the initial overflow guard reserved an unnecessary second at each endpoint
- Correction: check the endpoint fractions exactly and compute the negative floor-second case relative to the representable minimum
- Permanent check: both int64 endpoints, adjacent values, zero, and signed single-nanosecond values in `tests/test_fsmeta.nim`
