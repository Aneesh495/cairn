# Operator guide

All normal commands emit JSON to stdout. Diagnostics go to stderr. Help and
version are plain text. Quote shell globs so the shell does not expand them.
Use `--` when an operand begins with a hyphen.

## Start with a synthetic walkthrough

```sh
make build
make demo
```

The demo owns a newly created `.runtime/demo` directory. It never operates on
an existing user archive. A second run needs a new destination, for example:

```sh
./bin/cairn demo .runtime/another-run
```

The result names its source, archive, restored tree, damage JSON, repair plan,
snapshot diff, and offline report. Open `report.html` directly in a browser.

## Initialize

The repository's parent directory must already exist, and the repository path
must be new:

```sh
./bin/cairn init ./archive
./bin/cairn init ./small-archive --data 3 --parity 2
```

The geometry and chunking configuration are immutable. To change them, restore
or extract the data and acquire it into a new repository. Default chunk bounds
are 16/64/256 KiB, with four data and two parity positions.

For a workload-specific geometry:

```sh
./bin/cairn init ./custom-archive \
  --data 4 --parity 2 \
  --chunk-min 16384 --chunk-avg 65536 --chunk-max 262144
```

Average chunk size must be a power of two. Minimum, average, and maximum must be
ordered. Higher parity increases storage and write work. Smaller chunks improve
reuse granularity but increase file count, metadata, hashes, and flushes.

## Acquire revisions

```sh
./bin/cairn backup ./archive ./dataset run_001
./bin/cairn backup ./archive ./dataset run_002 \
  --exclude 'cache/' --exclude '*.tmp'
./bin/cairn snapshots ./archive
./bin/cairn diff ./archive run_001 run_002
./bin/cairn stats ./archive
```

Labels allow ASCII letters, digits, hyphen, and underscore, up to 80 bytes.
They are immutable names. Reusing a label fails rather than replacing history.

The source must be a real directory. Source and archive trees must be disjoint.
Special files and unsafe links fail acquisition. Detected source mutation
aborts before publishing a root; already written capsules can be collected
later if unreachable.

No mtime-only content cache is used. Files are read and hashed again during
acquisition. Unchanged content packets are reused after exact comparison.
Statistics name data-packet writes separately from manifest and root overhead.

### Exclusion rules

| Pattern | Meaning |
|---|---|
| `*.tmp` | Match that basename at any depth |
| `/root.log` | Match only the root-relative path |
| `cache/` | Match directories with that basename |
| `a/*/b` | Match exactly one intermediate component |
| `a/**/b` | Match zero or more intermediate directories |
| `!keep.tmp` | Re-include a later matching path |

Rules apply in order. An excluded directory is pruned, so a later include rule
cannot reach a child of that pruned directory. Include the parent first if a
child needs to remain visible. Wildcards match UTF-8 bytes; `?` is one byte.
Bracket classes and shell brace expansion are not part of this grammar.

## Check and inspect

```sh
./bin/cairn inspect ./archive run_002
./bin/cairn check ./archive run_002
./bin/cairn find ./archive run_002 '**/*.bin'
./bin/cairn history ./archive nested/file.bin
```

Default `check` verifies shard digests, reconstructs every referenced capsule,
checks surplus parity equations, and hashes every complete file. It also reports
missing and corrupt root copies.

`--fast` skips object reconstruction and complete-file hashing. Its output
marks `decode_verification=false` and `file_digests_verified=false`. Use it for
quick inspection, then run a full check before relying on restored data.

`stats` separates logical bytes across readable snapshots, distinct referenced
chunk bytes, and physical packet bytes read. Missing media or unreadable content
make accounting explicitly incomplete.

## Restore or extract

```sh
./bin/cairn restore ./archive run_002 ./recovered
./bin/cairn extract ./archive run_002 nested/file.bin ./one-file.bin
```

The output parent must exist. The output name must not exist, even as a dangling
symlink. Restore does not merge trees or delete existing destinations.

The final directory is published after complete-file verification and flushes.
A failed restore removes its owned private tree. A killed process may leave a
hidden `.cairn-restore-*` directory next to the requested destination. It remains
separate from the final output. Inspect and remove abandoned staging directories
only when no operation is using them.

## Examine media loss

```sh
./bin/cairn simulate ./archive run_002 --unavailable 0,1
./bin/cairn plan ./archive run_002 --costs 8,5,3,2,1,9
./bin/cairn envelope ./archive run_002 --max-loss 3 --max-cases 10000
./bin/cairn report ./archive run_002 ./recovery.html
```

Simulation is read-only. Media costs are operator-defined nonnegative integers.
The planner reports whether its result is proved optimal. Envelope output
reports whether its requested case set was fully enumerated. Preserve these
flags when consuming the JSON in another tool.

The HTML file contains no external resources. Search and state filters operate
locally. Large views display a capped row set; JSON reports retain the complete
map. The report is an inspection artifact, not a live view of subsequent changes.

## Repair

```sh
./bin/cairn repair ./archive run_002 > repair.json
./bin/cairn apply-repair ./archive repair.json
./bin/cairn check ./archive run_002
```

To plan and apply under normal stale-plan protection in one command:

```sh
./bin/cairn repair ./archive run_002 --apply
```

Budgets restrict replacement packets, including their headers:

```sh
./bin/cairn repair ./archive run_002 --max-bytes 10485760 --max-packets 100
```

Plans capture exact target preimages. A repaired, replaced, newly created, or
removed target makes an old plan stale. Do not edit hashes to force it through;
generate a fresh plan. Reference repair can still write small root/configuration
records when a data-packet budget is exhausted. Budgets describe packet work,
not a hard total-I/O quota.

The plan lists lost objects that cannot be reconstructed. Repair cannot recreate
those bytes without additional surviving media or a separately held source.

## Salvage

```sh
./bin/cairn salvage ./archive run_002 ./salvaged
```

This requires a readable manifest. Read `salvage.json` before using fragments.
Complete files are hashed and placed under `complete/`. Incomplete files remain
separate fragments with original offsets and lengths. No placeholder pretends
to be a complete restored file. Output I/O failure aborts the whole publication.

## Detached media and missing roots

```sh
./bin/cairn scan /media/volume-2
./bin/cairn assemble ./rescued \
  /media/volume-2 /media/volume-3 /media/volume-4 /media/volume-5
./bin/cairn check ./rescued run_002
```

Volume metadata must identify the same repository. Assembly does not require
the original top-level configuration or lock inode. It reads validated `.cap`
files recursively and recognizes their positions from their headers, even if
the input filenames changed. Source media are never moved or modified.

For total loss of root records:

```sh
./bin/cairn discover-snapshots ./archive
./bin/cairn recover-root ./archive MANIFEST_CONTENT_ID
```

Select the manifest deliberately. Discovery can expose snapshots that were
previously forgotten but have not yet been collected.

## Portable transport

```sh
./bin/cairn export ./archive run_002 ./run_002.cairn
./bin/cairn import ./run_002.cairn ./imported
./bin/cairn check ./imported run_002
```

Export includes the selected snapshot's content graph and surviving validated
shards. Import requires a complete graph and verifies the final frame transcript
before publishing a new repository. A single bundle is one transport file; its
internal shards do not create independent physical failure domains.

## Retain, forget, then collect

```sh
./bin/cairn retention ./archive --last 7 --daily 14 --weekly 8 --monthly 12 --pin run_001
./bin/cairn forget ./archive run_002
./bin/cairn forget ./archive run_002 --apply
./bin/cairn gc ./archive > gc.json
./bin/cairn gc ./archive --apply gc.json
```

Retention produces a decision only. Calendar buckets use UTC and retain the
newest snapshot in each selected bucket. Forgetting removes root records, while
GC separately reclaims unreachable capsules. Shared data survives as long as
any retained root references it.

Destructive maintenance requires every volume to be present. This prevents an
offline root copy from returning later and naming data that GC deleted while
that copy was invisible. A damaged reference blocks strict GC planning. Repair
or explicitly resolve the root before collecting.

GC plans bind the exact snapshot set and every physical packet preimage. A new
snapshot, repaired packet, changed root, or previous partial collection makes a
saved plan stale. Replan after an interruption.

## Exit statuses

| Status | Meaning |
|---:|---|
| 0 | Requested operation completed within its stated scope |
| 1 | I/O or host-runtime failure |
| 2 | Invalid input, unsupported path, or configured limit |
| 3 | Missing or unrecoverable required content; also a repair plan with lost objects |
| 4 | Corruption, conflict, stale plan, degraded check, or repair with deferred packets |
| 5 | Conflicting repository operation holds the lock |

Preserve the JSON report when a check returns 3 or 4. Its distinction between
recoverability, degradation, and complete verification is more useful than a
single boolean.
