import std/[unittest, strutils]
import cairn/[compression, prng, errors]

suite "bounded capsule compression":
  test "runs, literals, and token boundaries round trip":
    for size in 0..400:
      for data in [repeat('a', size), repeat("abc", size), repeat("aab", size)]:
        check decodeRuns(encodeRuns(data), data.len) == data
        let c = compress(data)
        check c.bytes.len <= data.len
        check decompress(c.codec, c.bytes, data.len) == data
  test "random binary round trips":
    var rng = Prng(state: 83)
    for trial in 0..<500:
      let data = rng.bytes(rng.bounded(2000))
      check decodeRuns(encodeRuns(data), data.len) == data
  test "all truncated encodings fail expected-length verification":
    let data = repeat('a', 260) & "different literals" & repeat('z', 131)
    let encoded = encodeRuns(data)
    for cut in 0..<encoded.len:
      expect CairnError: discard decodeRuns(encoded[0..<cut], data.len)
  test "decompression bombs and trailing tokens reject":
    expect CairnError: discard decodeRuns("\xffx", 1)
    expect CairnError: discard decodeRuns("\x00", 1)
    expect CairnError: discard decodeRuns("\x80", 3)
    expect CairnError: discard decodeRuns("\x00a\x00b", 1)
    expect CairnError: discard decompress(cpRaw, "abc", 2)
