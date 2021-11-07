## Reproducible kernel timings. Every measured path validates its result. The
## raw repetitions are retained so a median is not mistaken for a guarantee.
import std/[json, monotimes, times]
import cairn/[chunker, compression, erasure, prng, sha256]

proc seconds(start: MonoTime): float64 =
  float64((getMonoTime()-start).inNanoseconds) / 1_000_000_000.0

proc measurement(name: string; bytes: int; operation: proc() {.closure.}): JsonNode =
  var durations = newJArray()
  for repetition in 0..<10:
    let start = getMonoTime()
    operation()
    durations.add %seconds(start)
  %*{"name": name, "bytes_per_repetition": bytes, "repetitions": 10, "seconds": durations}

proc main() =
  var rng = Prng(state: 0xbec4'u64)
  let data = rng.bytes(4*1024*1024)
  let expectedHash = sha256(data)
  var output = %*{"seed": "bec4", "timing": "wall clock; correctness assertions included",
      "measurements": []}
  output["measurements"].add measurement("sha256", data.len, proc() =
    doAssert sha256(data) == expectedHash)
  output["measurements"].add measurement("content_defined_chunking", data.len, proc() =
    let parts = chunks(data)
    var total = 0
    for part in parts: total += part.len
    doAssert total == data.len)
  output["measurements"].add measurement("run_codec_incompressible", data.len, proc() =
    let compressed = compress(data)
    doAssert decompress(compressed.codec, compressed.bytes, data.len) == data)
  let code = initCode(Geometry(data: 4, parity: 2))
  let encoded = code.encode(data)
  output["measurements"].add measurement("reed_solomon_4_2_encode", data.len, proc() =
    let shards = code.encode(data)
    doAssert shards == encoded)
  let survivors = @[encoded[2], encoded[3], encoded[4], encoded[5]]
  output["measurements"].add measurement("reed_solomon_4_2_decode", data.len, proc() =
    doAssert code.decode(survivors, data.len) == data)
  echo $output

when isMainModule: main()
