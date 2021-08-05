import std/[unittest, strutils, sequtils, sets]
import cairn/[chunker, prng, sha256, errors]

suite "streaming content-defined boundaries":
  let config = ChunkConfig(minimum: 64, average: 256, maximum: 1024)
  test "empty and tiny streams":
    check chunks("", config).len == 0
    check chunks("tiny", config) == @["tiny"]
  test "buffer partition does not change boundaries":
    var rng = Prng(state: 71)
    let data = rng.bytes(60_000)
    let expected = chunks(data, config)
    check expected.join("") == data
    for stride in [1, 3, 63, 64, 65, 255, 1024, 4093]:
      var chunker = initChunker(config)
      var actual: seq[string]
      let collect = proc(chunk: string) = actual.add chunk
      var at = 0
      while at < data.len:
        let stop = min(at + stride, data.len)
        chunker.feed(data[at..<stop], collect)
        at = stop
      chunker.finish(collect)
      chunker.finish(collect)
      check actual == expected
    for i, chunk in expected:
      check chunk.len <= config.maximum
      if i < expected.high: check chunk.len >= config.minimum
  test "a prefix insertion preserves most later chunks":
    var rng = Prng(state: 72)
    let data = rng.bytes(100_000)
    let before = chunks(data, config).mapIt(sha256(it)).toHashSet
    let after = chunks("inserted prefix" & data, config).mapIt(sha256(it)).toHashSet
    check (before * after).len * 100 div before.len > 95
  test "repeated and zero data respect the maximum":
    for byte in ['\0', 'a', '\xff']:
      let data = repeat(byte, 10000)
      let parts = chunks(data, config)
      check parts.join("") == data
      for part in parts: check part.len <= 1024
  test "invalid configurations reject":
    for bad in [ChunkConfig(minimum: 0, average: 256, maximum: 1024),
                ChunkConfig(minimum: 128, average: 64, maximum: 1024),
                ChunkConfig(minimum: 64, average: 255, maximum: 1024),
                ChunkConfig(minimum: 64, average: 256, maximum: 128)]:
      expect CairnError: discard initChunker(bad)
