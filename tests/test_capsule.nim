import std/[unittest, strutils]
import cairn/[capsule, erasure, errors, crc32c, binary, prng]

proc resignHeader(bytes: var string) =
  var check = ""
  check.putU32(crc32c(bytes[0..<HeaderBytes-4]))
  bytes[HeaderBytes-4..<HeaderBytes] = check

suite "self-describing recovery capsules":
  test "surplus parity must agree with the recovered data":
    var packets = makePackets(okData, "surplus parity consistency", Geometry(data: 2, parity: 2))
    packets[^1].payload[0] = char(uint8(packets[^1].payload[0]) xor 1)
    # Re-serialization supplies valid per-packet checksums. The algebraic
    # inconsistency must still be caught at the complete-capsule boundary.
    packets[^1] = parsePacket(packets[^1].serialize)
    expect CairnError: discard recover(packets)
  let g = Geometry(data: 4, parity: 2)
  test "raw and compressed objects recover from parity":
    var rng = Prng(state: 91)
    for data in ["", "a", repeat('x', 1000), rng.bytes(1501)]:
      for kind in [okData, okManifest]:
        let all = makePackets(kind, data, g)
        var selected: seq[Packet]
        for i in [2, 3, 4, 5]: selected.add parsePacket(all[i].serialize)
        check recover(selected) == data
  test "every packet truncation rejects":
    let bytes = makePackets(okData, "hello world", g)[0].serialize
    for length in 0..<bytes.len:
      expect CairnError: discard parsePacket(bytes[0..<length])
    expect CairnError: discard parsePacket(bytes & "tail")
  test "every single-byte header corruption rejects":
    let bytes = makePackets(okData, repeat('x', 100), g)[0].serialize
    for offset in 0..<HeaderBytes:
      var corrupt = bytes
      corrupt[offset] = char(uint8(corrupt[offset]) xor 1)
      expect CairnError: discard parsePacket(corrupt)
  test "payload corruption rejects before decode":
    var bytes = makePackets(okData, "random small data", g)[0].serialize
    bytes[^1] = char(uint8(bytes[^1]) xor 1)
    expect CairnError: discard parsePacket(bytes)
  test "valid CRC does not bypass schema checks":
    let original = makePackets(okData, "hello", g)[0].serialize
    for offset in [8, 10, 11, 12, 13, 14, 15, 16, 24, 32, 40, 104]:
      var bytes = original
      bytes[offset] = '\xff'
      resignHeader(bytes)
      expect CairnError: discard parsePacket(bytes)
  test "mixed objects, duplicate shards, and false payload reject":
    var all = makePackets(okData, "hello", g)
    let other = makePackets(okData, "world", g)
    expect CairnError: discard recover(@[all[0], all[1], all[2], other[3]])
    expect CairnError: discard recover(@[all[0], all[0], all[1], all[2]])
    all[0].payload[0] = 'z'
    expect CairnError: discard recover(all[0..3])
