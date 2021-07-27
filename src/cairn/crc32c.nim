## Castagnoli CRC for quickly rejecting torn envelopes. SHA-256 is checked
## independently after decoding; CRC is not used as content identity.
func makeTable(): array[256, uint32] =
  for i in 0..255:
    var c = uint32(i)
    for bit in 0..<8:
      c = (c shr 1) xor (if (c and 1) != 0: 0x82f63b78'u32 else: 0'u32)
    result[i] = c

const Table = makeTable()

proc crc32c*(data: string): uint32 =
  var c = high(uint32)
  for b in data: c = Table[int((c xor uint32(uint8(b))) and 255)] xor (c shr 8)
  not c
