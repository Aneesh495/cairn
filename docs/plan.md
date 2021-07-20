# Implementation plan

Cairn is a local archive and recovery tool for directory trees that need to
remain readable after storage damage. The executable and archive engine are
written in Nim. It should be useful on an unplugged laptop with no database,
service, package registry, or account.

## Product contract

1. Archive a directory into immutable, globally deduplicated content capsules
2. Spread systematic erasure shards across independently movable volumes
3. Recover an object from any sufficient set of validated shards
4. Reconstruct the object catalog by inspecting capsule headers
5. Explain which files survive a given damage pattern before restoring
6. Restore into a new destination, verify file hashes, then publish the tree
7. Repair damaged shards without changing snapshot identities
8. Reclaim unreachable objects only through an explicit, inspectable plan

Snapshots describe ordinary files, directories, permissions, timestamps, and
symbolic links. Special files are rejected. Source changes during a backup
fail the operation. Cairn does not claim a coherent snapshot of live databases.

## Design boundary

The initial product targets POSIX macOS and Linux. No network backend,
encryption, FUSE, live database backup, ACL/xattr preservation, or privileged
device access is required. SHA-256 detects accidental corruption and binds
object identities. It does not authenticate an archive against a malicious
writer. Readers and writers use a repository lock to keep maintenance safe.

## Checkpoints

Each checkpoint should leave a reviewable commit. Regressions get permanent
tests. Compilation errors are corrected before a checkpoint is accepted.

| Phase | Checkpoints |
|---|---|
| Foundation | project contract; build layout; typed errors; bounded binary codec; SHA-256; CRC32C; deterministic test utilities |
| Recovery kernel | GF(256); matrix inversion; systematic Reed-Solomon; erasure tests; chunk boundaries; streaming chunker; bounded compression |
| Archive format | capsule envelope; strict metadata schemas; path validation; manifest codec; durable file I/O; repository locking; repository creation |
| Storage | capsule placement; validated reads; object discovery; reference replication; snapshot publication; streaming backup |
| Product | list and inspect; transactional restore; damage assessment; repair; snapshot diff; retention; garbage collection; import/export |
| Inspection | recovery planner; salvage; volume simulation; JSON reports; terminal CLI; offline HTML report |
| Verification | independent Python format oracle; randomized campaigns; crash boundaries; filesystem attacks; CLI workflows; reproducible benchmarks |
| Delivery | architecture diagrams; format specification; operator guide; developer guide; CI; clean-clone acceptance; publication |

## Acceptance

- Debug and release builds with runtime checks enabled
- Known-answer SHA-256 and CRC32C vectors and independent hashlib comparison
- Every admissible erasure pattern for small coding geometries
- Randomized codec, chunking, compression, and reconstruction properties
- Multi-snapshot backup, deduplication, volume loss, corruption, repair, restore
- Traversal, symlink, malformed length, invalid metadata, and lock rejection
- Actual subprocess termination at durable publication boundaries
- Independent archive inspection and restored-byte comparison
- Fresh clone build and demonstration with no network at runtime
- Source-bound raw verification report, with unavailable checks identified

The requested code scale is a planning guide. Production mechanisms, useful
tests, and maintainable examples take priority over repeated or generated code.
