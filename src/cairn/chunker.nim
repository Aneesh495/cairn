## Normalized gear-hash content-defined chunking. The stream state, gear table,
## and masks are format-stable. Boundaries do not depend on read buffer sizes.
import std/bitops
import cairn/[errors, limits, prng]

type
  ChunkConfig* = object
    minimum*: int
    average*: int
    maximum*: int
  ChunkConsumer* = proc(data: string) {.closure.}
  Chunker* = object
    config*: ChunkConfig
    pending: string
    rolling: uint64
    earlyMask: uint64
    lateMask: uint64

const DefaultChunks* = ChunkConfig(minimum: DefaultMinChunk,
  average: DefaultAvgChunk, maximum: DefaultMaxChunk)

func gearTable(): array[256, uint64] =
  var rng = Prng(state: 0x636169726e2d7631'u64)
  for i in 0..255: result[i] = rng.next

const Gear* = gearTable()

proc validate*(config: ChunkConfig) =
  require(config.minimum >= 64 and config.minimum <= config.average and
          config.average <= config.maximum and config.maximum <= MaxObjectBytes,
          ekInvalid, "chunk sizes must satisfy 64 <= min <= avg <= max <= 64 MiB")
  require((config.average and (config.average - 1)) == 0,
          ekInvalid, "average chunk size must be a power of two")

proc initChunker*(config = DefaultChunks): Chunker =
  config.validate
  result.config = config
  result.pending = newStringOfCap(config.maximum)
  let bits = fastLog2(uint64(config.average))
  result.earlyMask = (1'u64 shl (bits+1)) - 1
  result.lateMask = (1'u64 shl (bits-1)) - 1

proc emit(chunker: var Chunker; consume: ChunkConsumer) =
  let ready = chunker.pending
  chunker.pending = newStringOfCap(chunker.config.maximum)
  chunker.rolling = 0
  consume(ready)

proc feed*(chunker: var Chunker; data: string; consume: ChunkConsumer) =
  for b in data:
    chunker.pending.add b
    let length = chunker.pending.len
    # Skipping the pre-minimum prefix is part of the specified algorithm.
    if length < chunker.config.minimum: continue
    chunker.rolling = (chunker.rolling shl 1) + Gear[uint8(b)]
    let mask = if length < chunker.config.average: chunker.earlyMask else: chunker.lateMask
    if length == chunker.config.maximum or (chunker.rolling and mask) == 0:
      chunker.emit(consume)

proc finish*(chunker: var Chunker; consume: ChunkConsumer) =
  if chunker.pending.len > 0: chunker.emit(consume)

proc chunks*(data: string; config = DefaultChunks): seq[string] =
  var output: seq[string]
  let collect = proc(chunk: string) = output.add chunk
  var chunker = initChunker(config)
  chunker.feed(data, collect)
  chunker.finish(collect)
  output
