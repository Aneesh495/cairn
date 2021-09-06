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
