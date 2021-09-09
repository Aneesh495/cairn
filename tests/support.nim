## Real-filesystem fixtures shared by product integration tests. Test data is
## deterministic, binary, and deliberately deduplicated across multiple files.
import std/[os, tempfiles]
import cairn/[backup, chunker, erasure, prng, repository, restore, snapshot]

type Fixture* = object
  root*: string
  source*: string
  repo*: Repository
  snapshot*: Snapshot

proc fixture*(geometry = Geometry(data: 3, parity: 2)): Fixture =
  result.root = createTempDir("cairn-fixture-", "")
  result.source = result.root / "source"
  createDir(result.source / "nested")
  var rng = Prng(state: 0x434149524e'u64)
  let shared = rng.bytes(12_000)
  writeFile(result.source / "a.bin", shared)
  writeFile(result.source / "b.bin", shared)
  writeFile(result.source / "empty", "")
  writeFile(result.source / "nested" / "other", rng.bytes(4000))
  result.repo = initialize(result.root / "archive", geometry,
    ChunkConfig(minimum: 256, average: 1024, maximum: 4096))
  result.snapshot = result.repo.backup(result.source, "first").snapshot

proc cleanup*(fixture: Fixture) = cleanupTree(fixture.root)
