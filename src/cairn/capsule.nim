## Self-describing, independently validated erasure packets. A packet names its
## content object, coding geometry, shard position, codec, lengths, and shard
## digest. No side index is required to understand or reconstruct a capsule.
import cairn/[binary, compression, crc32c, erasure, errors, limits, sha256]

type
  ObjectKind* = enum
    okData = 1, okManifest = 2
  Packet* = object
    kind*: ObjectKind
    codec*: Compression
    geometry*: Geometry
    index*: int
    originalLength*: int
    encodedLength*: int
    id*: string
    payload*: string

const
  PacketMagic* = "CAIRN001"
  HeaderBytes* = 172

proc domain*(kind: ObjectKind): string =
  case kind
  of okData: "data"
  of okManifest: "manifest"

proc validate*(packet: Packet) =
  packet.geometry.validate
  require(packet.index >= 0 and packet.index < packet.geometry.total,
          ekCorrupt, "packet index exceeds geometry")
  require(validId(packet.id), ekCorrupt, "invalid capsule content ID")
  require(packet.originalLength >= 0 and packet.originalLength <= MaxObjectBytes and
          packet.encodedLength >= 0 and packet.encodedLength <= MaxObjectBytes,
          ekLimit, "capsule lengths exceed format bound")
  require(packet.payload.len == shardLength(packet.encodedLength, packet.geometry),
          ekCorrupt, "packet payload width mismatch")
  if packet.codec == cpRaw:
    require(packet.originalLength == packet.encodedLength,
            ekCorrupt, "raw capsule lengths disagree")
  else:
    require(packet.encodedLength < packet.originalLength,
            ekCorrupt, "compressed capsule must be smaller than raw data")

proc serialize*(packet: Packet): string =
  packet.validate
  result = PacketMagic
  result.putU16(FormatVersion)
  result.putU8(uint8(packet.kind))
  result.putU8(uint8(packet.codec))
  result.putU8(uint8(packet.geometry.data))
  result.putU8(uint8(packet.geometry.parity))
  result.putU8(uint8(packet.index))
  result.putU8(0) # Reserved flags must remain zero in version 1.
  result.putU64(uint64(packet.originalLength))
  result.putU64(uint64(packet.encodedLength))
  result.putU64(uint64(packet.payload.len))
  result.add packet.id
  result.add sha256(packet.payload)
  doAssert result.len == HeaderBytes-4
  result.putU32(crc32c(result))
  result.add packet.payload

proc parsePacket*(bytes: string): Packet =
  require(bytes.len >= HeaderBytes and bytes.len <= HeaderBytes + MaxObjectBytes,
          ekCorrupt, "invalid packet file length")
  var checksum = Reader(data: bytes[HeaderBytes-4..<HeaderBytes])
  require(checksum.u32 == crc32c(bytes[0..<HeaderBytes-4]),
          ekCorrupt, "packet header CRC32C mismatch")
  var r = Reader(data: bytes)
  require(r.take(8) == PacketMagic, ekCorrupt, "invalid capsule magic")
  require(r.u16 == FormatVersion, ekCorrupt, "unsupported capsule version")
  let kind = r.u8
  let codec = r.u8
  require(kind in 1'u8..2'u8 and codec <= 1, ekCorrupt, "unknown capsule type or codec")
  result.kind = ObjectKind(kind)
  result.codec = Compression(codec)
  result.geometry = Geometry(data: int(r.u8), parity: int(r.u8))
  result.index = int(r.u8)
  require(r.u8 == 0, ekCorrupt, "unsupported capsule flags")
  result.originalLength = r.boundedInt(MaxObjectBytes)
  result.encodedLength = r.boundedInt(MaxObjectBytes)
  let width = r.boundedInt(MaxObjectBytes)
  result.id = r.take(64)
  let digest = r.take(64)
  discard r.u32 # Already checked before reading lengths.
  result.payload = r.take(width)
  r.finish
  result.validate
  require(validId(digest) and sha256(result.payload) == digest,
          ekCorrupt, "packet payload SHA-256 mismatch")

proc compatible*(a, b: Packet): bool =
  a.kind == b.kind and a.codec == b.codec and a.geometry == b.geometry and
  a.originalLength == b.originalLength and a.encodedLength == b.encodedLength and
  a.id == b.id

proc makePackets*(kind: ObjectKind; bytes: string; g: Geometry): seq[Packet] =
  require(bytes.len <= MaxObjectBytes, ekLimit, "object is too large")
  let compressed = compress(bytes)
  let code = initCode(g)
  let id = objectId(kind.domain, bytes)
  for shard in code.encode(compressed.bytes):
    result.add Packet(kind: kind, codec: compressed.codec, geometry: g,
      index: shard.index, originalLength: bytes.len,
      encodedLength: compressed.bytes.len, id: id, payload: shard.bytes)

proc recover*(packets: openArray[Packet]): string =
  require(packets.len > 0, ekUnrecoverable, "no valid packets for capsule")
  let first = packets[0]
  var shards: seq[Shard]
  for packet in packets:
    packet.validate
    require(compatible(first, packet), ekCorrupt, "inconsistent capsule headers")
    shards.add Shard(index: packet.index, bytes: packet.payload)
  let encoded = initCode(first.geometry).decode(shards, first.encodedLength)
  result = decompress(first.codec, encoded, first.originalLength)
  require(objectId(first.kind.domain, result) == first.id,
          ekCorrupt, "reconstructed object SHA-256 mismatch")
