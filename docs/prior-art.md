# Direction and prior art

## Portfolio inspection

The public inventory was refreshed on 2026-10-17 through GitHub's API. The
inspection covered repository descriptions, default-branch trees, README
files, and source samples. It was a direction survey, not an acceptance audit
of those repositories.

The closest existing projects were inspected more closely:

| Project | Observed area | Cairn's different responsibility |
|---|---|---|
| tessera | Zig LSM storage, manifest edits, retrieval indexes | Recover ordinary directory trees after physical archive damage |
| meridian | Go WAL recovery, transactional execution | Immutable offline capsules with no consensus or query engine |
| helix | Elixir storage behavior and replicated state | Portable storage media and index-free rescue |
| apogee | Erlang bundle storage and byte-error RS coding | Systematic shard erasures, per-file recoverability, verified restore |
| quartz | D communications coding and signal experiments | Operate on real filesystem datasets and durable archive volumes |
| crucible | C# controlled execution and fault exploration | Exercise actual archive files and subprocess crash boundaries |
| covenant | Document ingestion and analysis | Preserve arbitrary bytes, paths, and recovery dependencies |

Other projects cover compilers, hardware, mathematical kernels, market-data
execution, learning models, and application analytics. Cairn explores a
practical operator tool rather than adding another language runtime or solver.

## Existing archive work

[restic's design](https://github.com/restic/restic/blob/master/doc/design.rst)
and [Borg's internals](https://borgbackup.readthedocs.io/en/stable/internals.html)
are substantial prior art for content addressing and deduplicated snapshots.
Cairn does not claim to invent either technique or replace either tool.

[FastCDC](https://www.usenix.org/conference/atc16/technical-sessions/presentation/xia)
motivates normalized gear-hash chunk boundaries. Cairn specifies its own
stable gear table, boundary rules, capsule format, and recovery workflow.

The product emphasis is an explainable recovery envelope: independently
identifiable shards, replicated snapshot roots, content-verified decoding,
file-level loss maps, index-free discovery, and repair plans that can be
checked before any archive mutation. This is a particular integration of
established techniques, not a claim of a new coding theory algorithm.
