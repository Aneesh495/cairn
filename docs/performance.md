# Performance method

Cairn favors an inspectable recovery path and conservative publication ordering.
It does not claim to outperform general-purpose backup tools. Default behavior
includes repeated hashing, parity generation, packet comparison, and per-file
flushes that are intentional correctness costs.

## Kernel benchmark

```sh
make bench
```

`bench/bench.nim` uses deterministic 4 MiB binary input with seed `bec4`, ten
wall-clock repetitions per operation, and checked release compilation.
Each timed operation includes a correctness assertion.

| Measurement | Included work |
|---|---|
| `sha256` | Complete digest and expected-hash comparison |
| `content_defined_chunking` | Boundary computation, chunk allocation, and total-size check |
| `run_codec_incompressible` | Compression selection and exact decompression comparison |
| `reed_solomon_4_2_encode` | Complete data/parity generation and equality check |
| `reed_solomon_4_2_decode` | Reconstruction from positions 2, 3, 4, 5 and byte comparison |

JSON retains every repetition in seconds and the exact bytes per repetition.
Compute throughput as `bytes / seconds / 2^20`. Do not report a best repetition
as sustained archive throughput or compare runs with different correctness work.

These timings do not include disk I/O, manifest construction, repository locks,
source identity checks, packet envelopes, flushes, or directory publication.
They are kernel measurements only.

## End-to-end measurement

For an application workload, retain the dataset generator and seed, file-size
distribution, duplicate content, source byte count, geometry, chunk configuration,
filesystem, storage device, compiler flags, and every raw repetition.

Measure the complete command rather than extrapolating from kernel timings:

```sh
./bin/cairn backup ./archive ./dataset trial_001
./bin/cairn check ./archive trial_001
./bin/cairn restore ./archive trial_001 ./restored_001
```

Use a new immutable snapshot label and new restore destination for every trial.
Report first acquisition and deduplicated subsequent acquisition separately.
State whether data was cached by the operating system. A warm-cache restore is
not an uncached device benchmark.

The demo's write/reuse counts describe its deterministic dataset only. They are
not an expected deduplication ratio for unrelated workloads.

## Storage accounting

Three byte domains matter:

1. Logical bytes across readable snapshot file versions
2. Distinct referenced uncompressed data-chunk bytes
3. Physical packet bytes read, including headers and redundancy

Manifest and reference overhead are separate from data-packet acquisition
statistics. Orphan capsules can remain after interrupted acquisition or root
deletion. GC planning provides their explicit reclaimable byte count.

Missing media or unreadable metadata can make physical accounting incomplete.
The JSON exposes that state. Do not turn a partial physical inventory into an
archive-wide compression or deduplication claim.

## Memory and scaling tradeoffs

Chunk acquisition is streaming, but manifests and selected path identities are
held in memory. Encoding and recovery hold a bounded capsule and its shards.
The expansion factor depends on geometry; k=1 with many parity shards is much
larger than the default 4+2 case.

Every capsule position is a separate file. This makes detached discovery and
repair straightforward, at the cost of inode count and many flush operations.
Small chunks on a high-latency filesystem can therefore be expensive. Packing
capsules into indexed containers would require another recoverable metadata and
compaction protocol; it is not hidden behind the current format.

The recovery planner is exponential in the worst case. It has a deterministic
state bound and reports when optimality is unproved. Failure envelopes are
combinatorial and have a separate case bound. Neither budget changes content
integrity or silently reduces verification workloads.
