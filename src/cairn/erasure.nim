## Systematic MDS erasure coding. The first k shards are data; m parity shards
## are linear combinations over GF(256). A Vandermonde generator is normalized
## by the inverse of its top k rows, so every k-row subset remains invertible.
## Corrupt shards must be discarded by the envelope verifier before decode.
import std/sets
import cairn/[errors, limits, gf256, matrix]

type
  Geometry* = object
    data*: int
    parity*: int
  Shard* = object
    index*: int
    bytes*: string
  Code* = object
    geometry*: Geometry
    generator*: Matrix

proc total*(g: Geometry): int = g.data + g.parity

proc validate*(g: Geometry) =
  require(g.data >= 1 and g.data <= MaxDataShards, ekInvalid,
          "data shards must be in 1.." & $MaxDataShards)
  require(g.parity >= 1 and g.parity <= MaxShards - g.data, ekInvalid,
          "parity shards exceed geometry limit")

proc initCode*(g: Geometry): Code =
  g.validate
  var vandermonde = zeros(g.total, g.data)
  for row in 0..<g.total:
    for col in 0..<g.data:
      vandermonde[row][col] = power(uint8(row), col)
  var top = zeros(g.data, g.data)
  for row in 0..<g.data:
    for col in 0..<g.data: top[row][col] = vandermonde[row][col]
  result.geometry = g
  result.generator = multiply(vandermonde, invert(top))

proc shardLength*(length: int; g: Geometry): int =
  g.validate
  require(length >= 0 and length <= MaxObjectBytes, ekLimit,
          "object exceeds capsule limit")
  length div g.data + ord(length mod g.data != 0)

proc encode*(code: Code; data: string): seq[Shard] =
  let g = code.geometry
  let width = shardLength(data.len, g)
  result = newSeq[Shard](g.total)
  for i in 0..<g.total:
    result[i] = Shard(index: i, bytes: newString(width))
  for i in 0..<data.len:
    result[i div width].bytes[i mod width] = data[i]
  for row in g.data..<g.total:
    for col in 0..<g.data:
      multiplyAdd(result[row].bytes, result[col].bytes, code.generator[row][col])

proc decode*(code: Code; available: openArray[Shard]; length: int): string =
  let g = code.geometry
  let width = shardLength(length, g)
  require(available.len >= g.data and available.len <= g.total,
          ekUnrecoverable, "insufficient distinct shards")
  var seen = initHashSet[int]()
  for shard in available:
    require(shard.index >= 0 and shard.index < g.total, ekCorrupt, "invalid shard index")
    require(shard.index notin seen, ekCorrupt, "duplicate shard index")
    require(shard.bytes.len == width, ekCorrupt, "incorrect shard width")
    seen.incl(shard.index)
  var selected = zeros(g.data, g.data)
  for row in 0..<g.data:
    for col in 0..<g.data:
      selected[row][col] = code.generator[available[row].index][col]
  let inverse = invert(selected)
  result = newStringOfCap(width * g.data)
  for row in 0..<g.data:
    var decoded = newString(width)
    for col in 0..<g.data:
      multiplyAdd(decoded, available[col].bytes, inverse[row][col])
    result.add decoded
  # Padding is specified as zero and must not be a hidden data channel.
  for i in length..<result.len:
    require(result[i] == '\0', ekCorrupt, "nonzero erasure padding")
  result.setLen(length)

proc reconstruct*(code: Code; available: openArray[Shard]; length: int): seq[Shard] =
  code.encode(code.decode(available, length))
