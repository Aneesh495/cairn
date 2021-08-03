import std/[unittest, sequtils, strutils]
import cairn/[erasure, prng, errors]

proc combinations(n, k: int): seq[seq[int]] =
  var current: seq[int]
  var answers: seq[seq[int]]
  proc collect(start: int) =
    if current.len == k:
      answers.add current
      return
    for i in start..<n:
      current.add i
      collect(i+1)
      current.setLen(current.len-1)
  collect(0)
  answers

suite "systematic erasure coding":
  test "every sufficient subset for small geometries":
    var rng = Prng(state: 0x51)
    for k in 1..5:
      for m in 1..3:
        let code = initCode(Geometry(data: k, parity: m))
        for length in [0, 1, k-1, k, k+1, 31, 256]:
          let data = rng.bytes(length)
          let all = code.encode(data)
          check all[0..<k].mapIt(it.bytes).join("")[0..<data.len] == data
          for subset in combinations(k+m, k):
            let shards = subset.mapIt(all[it])
            check code.decode(shards, data.len) == data
  test "randomized arbitrary order and maximum geometry":
    var rng = Prng(state: 0x52)
    for trial in 0..<200:
      let k = rng.bounded(16)+1
      let m = rng.bounded(32-k)+1
      let code = initCode(Geometry(data: k, parity: m))
      let data = rng.bytes(rng.bounded(1000))
      var all = code.encode(data)
      rng.shuffle(all)
      all.setLen(k)
      check code.decode(all, data.len) == data
  test "invalid geometries and shard sets reject":
    for g in [Geometry(data: 0, parity: 2), Geometry(data: 17, parity: 1),
              Geometry(data: 2, parity: 0), Geometry(data: 16, parity: 17)]:
      expect CairnError: discard initCode(g)
    let code = initCode(Geometry(data: 2, parity: 2))
    let all = code.encode("abc")
    expect CairnError: discard code.decode(all[0..0], 3)
    expect CairnError: discard code.decode(@[all[0], all[0]], 3)
    expect CairnError: discard code.decode(@[all[0], Shard(index: 9, bytes: "aa")], 3)
    expect CairnError: discard code.decode(@[all[0], Shard(index: 1, bytes: "a")], 3)
  test "nonzero padding is rejected":
    let code = initCode(Geometry(data: 2, parity: 1))
    var all = code.encode("abc")
    all[1].bytes[1] = 'x'
    expect CairnError: discard code.decode(all[0..1], 3)
