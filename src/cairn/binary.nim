## Explicit little-endian wire primitives. No casts, host endianness, pointer
## reads, or unchecked length arithmetic enter the archive format.
import cairn/errors

type Reader* = object
  data*: string
  position*: int

proc remaining*(r: Reader): int = r.data.len - r.position

proc take*(r: var Reader; length: int): string =
  require(length >= 0 and length <= r.remaining, ekCorrupt,
          "truncated binary field at byte " & $r.position)
  result = r.data.substr(r.position, r.position + length - 1)
  r.position += length

proc u8*(r: var Reader): uint8 =
  require(r.remaining >= 1, ekCorrupt, "truncated byte")
  result = uint8(r.data[r.position])
  inc r.position

proc u16*(r: var Reader): uint16 =
  for shift in countup(0, 8, 8):
    result = result or (uint16(r.u8) shl shift)

proc u32*(r: var Reader): uint32 =
  for shift in countup(0, 24, 8):
    result = result or (uint32(r.u8) shl shift)

proc u64*(r: var Reader): uint64 =
  for shift in countup(0, 56, 8):
    result = result or (uint64(r.u8) shl shift)

proc boundedInt*(r: var Reader; maximum: int): int =
  let value = r.u64
  require(value <= uint64(maximum), ekLimit, "binary length exceeds limit")
  result = int(value)

proc finish*(r: Reader) =
  require(r.remaining == 0, ekCorrupt, "trailing binary bytes")

proc putU8*(s: var string; value: uint8) = s.add char(value)
proc putU16*(s: var string; value: uint16) =
  for shift in countup(0, 8, 8): s.add char((value shr shift) and 255)
proc putU32*(s: var string; value: uint32) =
  for shift in countup(0, 24, 8): s.add char((value shr shift) and 255)
proc putU64*(s: var string; value: uint64) =
  for shift in countup(0, 56, 8): s.add char((value shr shift) and 255)

proc putSized*(s: var string; value: string) =
  s.putU64(uint64(value.len))
  s.add value

proc sized*(r: var Reader; maximum: int): string =
  r.take(r.boundedInt(maximum))
