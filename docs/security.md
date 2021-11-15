# Integrity and filesystem boundaries

Cairn is an offline integrity and recovery tool for a locally controlled archive.
Its checks are designed to detect accidental damage and reject malformed input.
They do not establish authenticity against a writer who controls the archive.

## Trust boundary

Trusted inputs are the compiled executable, its local operating system, the
operator's selected repository root, and cooperative repository users who honor
the lock protocol. Archive bytes, metadata fields, paths, packet lengths, and
bundle frames are validated before use.

SHA-256 is used for identity and accidental-corruption detection. There are no
secret keys, signatures, authenticated roots, password protection, or encryption.
Anyone who can read the repository can read its data. A writer who replaces
both content and roots can construct a different internally consistent archive.

## Path policy

- Archive names must be valid UTF-8 and use relative POSIX components
- Empty components, `.`, `..`, leading `/`, backslash, colon, and NUL reject
- The manifest root is the one special path `.`
- Every non-root entry requires a directory parent
- Duplicate and unsorted paths reject
- A path below a managed root cannot traverse a pre-existing symbolic link
- The selected root is canonicalized once, allowing ordinary system aliases such as macOS `/var`
- Restore destinations must be new and outside the repository
- Sources and repositories must be disjoint

File contents remain arbitrary bytes. Non-UTF-8 filenames are deliberately
rejected rather than normalized or silently renamed.

Symbolic links must have relative UTF-8 targets that remain inside the restored
tree. Cairn validates the entire link graph using chained resolution, including
parent components after an intermediate link. Cycles and chains beyond 40
expansions reject. This is stricter than preserving arbitrary Unix symlinks.

## Local concurrency limits

Managed reads use `O_NOFOLLOW`, regular-file checks, bounded allocation, and
exact-length reads. Source acquisition uses inode and timestamp identity checks.
High-level operations hold shared or exclusive advisory locks.

These measures do not defend against a hostile local process concurrently
renaming parent directories outside the lock protocol. Managed-path checks are
not a capability sandbox. Do not expose a live repository to untrusted local
writers or run Cairn with elevated privileges over untrusted mutable directory
trees.

## Parser and resource limits

Binary lengths are checked before allocation. JSON nesting is bounded before
the standard parser runs. Canonical metadata validation rejects duplicate and
unknown fields. Decompression cannot exceed its declared, capped output size.
Geometry, path depth, entry count, and chunk-reference count are bounded.

The hard bounds still permit large allocations. A large one-data-shard capsule
with many parity positions has significant expansion. Use the default geometry
and chunk sizes unless a measured workload justifies another choice.

Planner state counts and failure-case enumeration have explicit budgets. Their
reports state when optimality or exhaustive enumeration was not established.

## Durability boundary

File contents are flushed before publishing their name, and containing
directories are flushed afterward. Immutable publication does not overwrite an
existing name. Snapshot content precedes root publication. Restore and import
publish new directory trees after verification.

Actual `SIGKILL` tests cover process interruption. They are not power-cut,
controller-cache, filesystem-journal, removable-device, or physical-media tests.
Durability ultimately depends on the host filesystem and storage stack honoring
the requested flush operations.

## Deliberate exclusions

Cairn does not preserve ACLs, extended attributes, ownership, setuid/setgid bits,
hard-link identity, sparse allocation, device files, sockets, or FIFOs. Ordinary
file bytes are preserved, including the logical zero bytes of sparse files.
Relative symlink targets are preserved; symlink-specific mode and timestamp
semantics are not promised across platforms.

Backup is not an application snapshot service. Quiesce mutable writers or
archive an external filesystem snapshot when transactional consistency matters.

## Reporting defects

Include the command, compiler version, platform, expected behavior, and a small
synthetic reproducer. Avoid attaching private archive content. The
[regression ledger](bugs.md) records observed behavioral defects, the failing
case, the correction, and its permanent test.
