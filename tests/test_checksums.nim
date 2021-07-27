import std/unittest
import cairn/[crc32c, prng]

suite "CRC32C and deterministic fixtures":
  test "Castagnoli reference values":
    check crc32c("") == 0'u32
    check crc32c("123456789") == 0xe3069283'u32
    check crc32c("The quick brown fox jumps over the lazy dog") == 0x22620404'u32
  test "SplitMix64 reference output":
    var rng = Prng(state: 0)
    check rng.next == 0xe220a8397b1dcdaf'u64
    check rng.next == 0x6e789e6aa1b965f4'u64
  test "fixtures are reproducible and include binary bytes":
    var a = Prng(state: 17)
    var b = a
    check a.bytes(1024) == b.bytes(1024)
    var items = @[0, 1, 2, 3, 4]
    a.shuffle(items)
    check items.len == 5
    for i in 0..4: check i in items
