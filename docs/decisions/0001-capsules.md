# 0001: independently discoverable capsules

Status: implemented

## Context

An archive can lose its catalog and one or more storage devices simultaneously.
A central index can improve lookup and packing efficiency, but it can also make
otherwise intact data difficult to identify after metadata loss.

## Decision

Every content object becomes independently described erasure packets. Each
packet records its object identity, kind, codec, geometry, lengths, position,
header CRC32C, and payload hash. Normal paths derive from the content ID, while
detached scans derive identity from the packet itself.

The manifest is a protected capsule too. Small root records are replicated into
every volume. Configuration is also replicated so a new top-level repository
can be assembled from surviving detached media.

## Consequences

Recovery does not require a central object index. Repair can target one packet
without rewriting a large container. A full manifest can be recovered from any
sufficient shard set, and every snapshot remains independently readable.

The cost is inode count, repeated headers, and many flushes. The first version
accepts that cost. Adding pack containers later requires a specified scan,
recovery, rewrite, and compaction protocol; it cannot silently replace packet
paths while keeping the same durability claims.

## Rejected alternatives

- A single mutable catalog as the authority for object locations
- A long chain of incremental manifests requiring previous snapshots
- One bundle file treated as if its internal shard records were independent devices

Portable bundles remain a transport representation with their own complete
transcript checks. They do not change physical failure domains.
