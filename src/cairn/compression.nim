## A bounded PackBits-like codec. Runs of 3..130 bytes use a two-byte token;
## literals of 1..128 bytes use a length token followed by their bytes. The
## encoder selects raw storage whenever this representation does not shrink.
import cairn/[errors, limits]

type
  Compression* = enum
    cpRaw = 0, cpRuns = 1
  Compressed* = object
    codec*: Compression
    bytes*: string

proc runLength(data: string; at: int): int =
  result = 1
  while result < 130 and at + result < data.len and data[at+result] == data[at]:
    inc result

proc encodeRuns*(data: string): string =
  require(data.len <= MaxObjectBytes, ekLimit, "compression input exceeds object limit")
  var at = 0
  while at < data.len:
    let run = runLength(data, at)
    if run >= 3:
      result.add char(128 + run - 3)
      result.add data[at]
      at += run
    else:
      let start = at
      inc at
      while at < data.len and at - start < 128 and runLength(data, at) < 3:
        inc at
      result.add char(at - start - 1)
      result.add data[start..<at]

proc decodeRuns*(encoded: string; expected: int): string =
  require(expected >= 0 and expected <= MaxObjectBytes, ekLimit,
          "decompression output exceeds object limit")
  result = newStringOfCap(expected)
  var at = 0
  while at < encoded.len:
    let token = int(uint8(encoded[at]))
    inc at
    if token >= 128:
      let count = token - 128 + 3
      require(at < encoded.len and count <= expected - result.len,
              ekCorrupt, "invalid compressed run")
      for i in 0..<count: result.add encoded[at]
      inc at
    else:
      let count = token + 1
      require(count <= encoded.len - at and count <= expected - result.len,
              ekCorrupt, "invalid compressed literal")
      result.add encoded[at..<at+count]
      at += count
  require(result.len == expected, ekCorrupt, "decompression length mismatch")

proc compress*(data: string): Compressed =
  let encoded = encodeRuns(data)
  if encoded.len < data.len: Compressed(codec: cpRuns, bytes: encoded)
  else: Compressed(codec: cpRaw, bytes: data)

proc decompress*(codec: Compression; data: string; expected: int): string =
  case codec
  of cpRaw:
    require(data.len == expected and expected <= MaxObjectBytes,
            ekCorrupt, "raw object length mismatch")
    data
  of cpRuns: decodeRuns(data, expected)
