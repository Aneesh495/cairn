# 0003: exact preimages for destructive maintenance

Status: implemented

## Context

A plan can be reviewed at one time and applied after other operations change
the repository. Reusing it without checking its assumptions can repair the
wrong preimage or delete newly referenced data.

## Decision

Repair actions bind exact before/after packet digests. GC binds the complete
root set and physical packet preimages. Application acquires the exclusive
lock and validates the entire plan before its first mutation.

GC requires every volume online and every discovered root readable. It derives
reachability from complete current manifests rather than approximate reference
counts. Forgetting roots and collecting data remain separate commands.

## Consequences

New snapshots, packet repairs, root changes, and partial applications invalidate
old plans. Replanning is the normal continuation path. It costs extra scans and
hashing, but it makes the operator's reviewed state concrete.

Checksums are integrity aids, not authorization signatures. A caller cannot
force a deletion by editing a plan checksum because application recomputes the
expected plan from the live archive.
