# Developer guide

## Toolchain

The implementation uses Nim's C backend, ORC memory management, and the standard
library. No Nimble packages or native third-party libraries are required.
Production code uses POSIX file APIs directly where atomic publication,
no-follow access, file descriptors, and flush ordering matter.

Supported build prerequisites:

- Nim 2.2.6 or newer, or the pinned compiler bootstrap
- A POSIX macOS or Linux host and a working C compiler
- Python 3.12+ for automatic compiler installation, verification, and evidence replay
- `curl` for automatic compiler download only
- `make` for the documented build entry points

```sh
make bootstrap
make build
./bin/cairn --version
```

Bootstrap fetches an official Nim 2.2.12 archive and verifies its pinned SHA-256
before extraction. It writes only `.toolchain/`. It does not change shell
profiles, the home directory, system packages, or global executable links.

```sh
CAIRN_OFFLINE=1 make build
make NIM=/absolute/path/to/nim build
make NIM=nim build
```

Offline mode succeeds with a supported compiler already available. Otherwise
it fails with an installation instruction rather than silently downloading.
The native executable itself performs no network requests.

The Nimble package also builds the same executable under `bin/`:

```sh
nimble check
nimble build
```

The package has no dependencies beyond the compiler. Nimble can maintain its
own package-list cache. Use `CAIRN_OFFLINE=1 make build` after compiler setup
for the enforced offline path. Make also owns complete verification and
evidence generation.

## Build targets

| Target | Purpose |
|---|---|
| `make build` | Checked release executable under `bin/` |
| `make test` | Debug unit/integration suites and captured raw log |
| `make test-release` | The same suites in checked release mode |
| `make campaign` | Deterministic randomized campaigns |
| `make verify` | Build, both suites, campaigns, and real-process acceptance |
| `make acceptance` | Verify, then freeze source-bound evidence |
| `make verify-evidence` | Validate saved evidence and current source binding |
| `make replay-evidence` | Independently decode the saved synthetic archive fixture |
| `make demo` | Acquire, damage, inspect, repair, and restore a synthetic dataset |
| `make bench` | Raw kernel timing repetitions with correctness assertions |
| `make clean` | Remove generated binaries and build outputs |

Release mode keeps assertions, overflow checks, and bounds checks enabled.
Do not use `-d:danger` for archive processing. The checks are part of malformed
input rejection and the format contract.

`NIMFLAGS` supplies additional compiler flags. For a sanitizer build with Clang:

```sh
make NIMFLAGS='--cc:clang --passC:-fsanitize=address,undefined --passL:-fsanitize=address,undefined --passC:-fno-omit-frame-pointer' test
```

## Source map

| Modules | Responsibility |
|---|---|
| `errors`, `limits`, `binary`, `schema` | Typed failures, allocation bounds, strict primitive decoders |
| `sha256`, `crc32c`, `prng` | Content identity, torn-header checks, deterministic fixtures |
| `gf256`, `matrix`, `erasure` | Field arithmetic and systematic coding |
| `chunker`, `compression`, `capsule` | Streaming boundaries, bounded codec, packet integrity |
| `paths`, `linkgraph`, `fsmeta` | Portable names, complete link confinement, source identity |
| `durable`, `streamio`, `locking` | Flush ordering, staged streaming files, advisory locks |
| `config`, `repository`, `store` | Layout, volume identity, content-addressed placement |
| `manifest`, `references`, `snapshot` | Complete tree schemas and root publication |
| `backup`, `restore`, `salvage` | High-level filesystem workflows |
| `damage`, `planner`, `survival`, `repair` | Physical evidence, media choice, failure envelopes, repair |
| `diff`, `query`, `retention`, `statistics`, `gc` | Navigation and maintenance |
| `scan`, `assemble`, `rescue` | Index-free and detached recovery |
| `framing`, `bundle` | Streaming transport and transcript validation |
| `htmlreport`, `arguments`, `cli`, `demo` | Local inspection and executable product interface |

## Adding a format feature

1. Define the persistent semantics and hard bounds in `format.md`
2. Add independent expected values or an independently written oracle
3. Add malformed-input and truncation rejection cases before wiring the CLI
4. Keep decoding separate from filesystem mutation
5. Update the Python reader when the archive format changes
6. Exercise the complete CLI path, including a negative case
7. Run both debug and release suites, campaigns, and acceptance
8. Regenerate saved evidence only after the source is frozen

Never loosen a parser or suppress an exception just to make a fixture pass.
If a record is accepted, its bounds, canonical representation, and semantics
must be specified. Unknown versions should fail visibly.

## Adding a filesystem operation

Decide which high-level lock protects the operation. Low-level helpers do not
acquire recursive locks. New mutators must use the exclusive lock; readers
must keep a shared lock for the entire multi-step read.

Use validated relative names and `managedPath` for repository-derived paths.
Use `readBounded` for managed regular files, `writeAtomic` for small immutable or
explicitly replaced records, and `StagedFile` for streaming output. Do not use
unbounded `readFile` on archive-controlled packets in production paths.

Keep destination writes outside source-damage classification handlers. A failed
read can be evidence of missing source data; a failed output write must abort
publication. Regression B005 exists because this boundary was previously wrong.

For operations that publish a tree, stage it beside the final destination on
the same filesystem. Verify content, flush owned files and directories, and
publish the new name only after those checks. Existing output names reject.

## Regression workflow

Every observed behavioral defect gets:

- A failing reproducer that demonstrates the old behavior
- A narrowly scoped correction
- A retained positive and negative test where applicable
- A ledger entry with the cause and permanent test location

The [ledger](bugs.md) separates behavioral failures from ordinary compiler
diagnostics during implementation. The real I/O regression uses `RLIMIT_FSIZE`;
crash tests use actual `SIGKILL` rather than simulated graceful exceptions.

## Extending analysis

Keep feasibility, optimality, exhaustive enumeration, and content verification
as separate facts. A state-budget limit must not become a successful proof.
A shard-count estimate must not become a decoded-content claim. A sum of
surviving fragments must not become complete-file bytes.

For a new planner, compare small randomized cases against an independently
written exhaustive oracle. Use deterministic seeds and preserve actual executed
case counts. Avoid tests that only call the same implementation twice.

## Evidence discipline

`tools/verify.py` captures a complete source manifest before acceptance and
requires the same bytes afterward. Generated outputs, compiler caches, Git
metadata, and the evidence directory are excluded from source binding.

The frozen receipt includes raw command stdout/stderr, independent-decoder
reports, debug/release test logs, campaign counts, environment information, and
a synthetic archive fixture. `tools/evidence.py` checks their hashes and derives
counts from those raw artifacts. Replay uses only the independent reader.

If source changes, old evidence is stale. A successful compiler invocation is
not an acceptance result. Update the receipt only by rerunning its generator.

## Code style

Use two-space Nim indentation and explicit names for persistent fields. Explain
invariants and failure ordering in comments. Keep host-specific code concentrated
in filesystem and lock modules. Keep the portable coding and format kernel
independent of terminal output or global repository state.

Use `nimpretty --maxLineLen:100` for ordinary Nim source. Avoid gratuitous
abstraction around one-line field operations. Do not introduce generated source
or duplicate subsystems to make the repository larger. Comments and docs use
plain punctuation and no em dash characters.
