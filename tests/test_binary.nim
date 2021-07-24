import std/unittest
import cairn/[binary, errors]

suite "bounded binary codec":
  test "unsigned fields preserve their full width":
    var s = ""
    s.putU8(255)
    s.putU16(0xbeef)
    s.putU32(0xfedcba98'u32)
    s.putU64(high(uint64))
    s.putSized("\0binary\xff")
    var r = Reader(data: s)
    check r.u8 == 255
    check r.u16 == 0xbeef
    check r.u32 == 0xfedcba98'u32
    check r.u64 == high(uint64)
    check r.sized(100) == "\0binary\xff"
    r.finish
  test "empty field does not consume the next byte":
    var r = Reader(data: "x")
    check r.take(0) == ""
    check r.u8 == uint8('x')
  test "all truncations reject":
    for length in 0..<8:
      var r = Reader(data: newString(length))
      expect CairnError: discard r.u64
  test "untrusted allocation lengths reject before allocation":
    var s = ""
    s.putU64(high(uint64))
    var r = Reader(data: s)
    expect CairnError: discard r.sized(32)
  test "negative and oversized slices reject":
    var r = Reader(data: "a")
    expect CairnError: discard r.take(-1)
    expect CairnError: discard r.take(2)
    expect CairnError: r.finish
