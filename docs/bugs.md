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
