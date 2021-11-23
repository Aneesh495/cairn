# 0002: immutable content before replicated roots

Status: implemented

## Context

A process can die between any two writes. It is easier to reason about
unreachable immutable content than a root that names unfinished file bytes.

## Decision

Write and flush all data packets, revalidate the source identities, verify the
complete file graph, store and flush the manifest capsule, then publish root
copies. The first valid root is the visibility boundary.

Small files use private same-directory staging, file fsync, immutable link or
explicit replacement, and parent-directory fsync. Restore and import build
private trees and publish a new directory name after verification.

## Consequences

Interrupted acquisition before root publication leaves orphans. Interrupted
root replication leaves a readable snapshot with degraded metadata redundancy.
GC and reference repair handle those cases without a transactional database.

Flushes cost latency. Process-crash tests validate interruption semantics, but
they do not prove power-cut behavior of every filesystem or storage controller.
That limit remains explicit in the receipt and threat model.
