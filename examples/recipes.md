# Small inspection recipes

Run these from the repository root after `make build`. Use synthetic or copied
data while learning the commands.

## Observe content-defined reuse

1. Create a directory with a binary file and a second identical copy
2. Initialize a new archive outside that source directory
3. Acquire snapshot `before`
4. Insert a short prefix into one source file
5. Acquire snapshot `after`
6. Compare `data_packets_written` and `data_packets_reused`
7. Run `diff`, then restore both revisions into distinct new directories

`make demo` executes this pattern over a deterministic dataset and compares the
restored bytes. Its expected reuse is specific to that dataset.

## Inspect a detached packet

```sh
./bin/cairn inspect-packet /path/to/object.cap
./bin/cairn scan /path/to/detached-volume
```

`inspect-packet` validates one packet's local header and payload. Complete
capsule verification additionally requires enough shards and coding-equation
checks. A valid individual packet is not a complete file recovery claim.

## Ask which media to retrieve

```sh
./bin/cairn plan ./archive run_001 --costs 10,10,2,1,3,8
```

The cost list follows volume index order and must contain every position.
Zero-cost media are permitted. Check `feasible`, `optimal`, and `lower_bound`
before using the selected set as a proved minimum-cost decision.

## Preserve a repair plan

```sh
./bin/cairn repair ./archive run_001 > repair.json
./bin/cairn apply-repair ./archive repair.json
./bin/cairn check ./archive run_001
```

If the archive changes after planning, application can reject the plan as stale.
Generate a fresh plan. Do not replace its preimage hashes by hand.

## Inspect the retained acceptance fixture

```sh
make verify-evidence
make replay-evidence
```

Replay independently reconstructs both retained synthetic snapshots across all
sufficient shard subsets. It does not need the original temporary test source
directory or a running Cairn process.
