## Streaming SHA-256, FIPS 180-4. This module supplies content identity and
## corruption detection, not signatures or encryption. State is copied when
## finalizing so callers can inspect a prefix without consuming the stream.
import std/[bitops, strutils]
import cairn/errors

type Sha256* = object
  state: array[8, uint32]
  buffer: array[64, uint8]
  used: int
  total: uint64

const Round = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
  0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
  0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
  0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
  0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
  0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
  0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
  0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
  0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
  0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
  0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
  0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
  0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
  0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
  0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
  0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]

proc initSha256*(): Sha256 =
  result.state = [0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
                  0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]

proc transform(ctx: var Sha256) =
  var words: array[64, uint32]
  for i in 0..<16:
    let j = i * 4
    words[i] = (uint32(ctx.buffer[j]) shl 24) or
               (uint32(ctx.buffer[j+1]) shl 16) or
               (uint32(ctx.buffer[j+2]) shl 8) or uint32(ctx.buffer[j+3])
  for i in 16..<64:
    let x = words[i-15]
    let y = words[i-2]
    let a = rotateRightBits(x, 7) xor rotateRightBits(x, 18) xor (x shr 3)
    let b = rotateRightBits(y, 17) xor rotateRightBits(y, 19) xor (y shr 10)
    words[i] = words[i-16] + a + words[i-7] + b
  var a = ctx.state[0]
  var b = ctx.state[1]
  var c = ctx.state[2]
  var d = ctx.state[3]
  var e = ctx.state[4]
  var f = ctx.state[5]
  var g = ctx.state[6]
  var h = ctx.state[7]
  for i in 0..<64:
    let s1 = rotateRightBits(e, 6) xor rotateRightBits(e, 11) xor rotateRightBits(e, 25)
    let choose = (e and f) xor ((not e) and g)
    let t1 = h + s1 + choose + Round[i] + words[i]
    let s0 = rotateRightBits(a, 2) xor rotateRightBits(a, 13) xor rotateRightBits(a, 22)
    let majority = (a and b) xor (a and c) xor (b and c)
    let t2 = s0 + majority
    h = g
    g = f
    f = e
    e = d + t1
    d = c
    c = b
    b = a
    a = t1 + t2
  for i, v in [a, b, c, d, e, f, g, h]:
    ctx.state[i] = ctx.state[i] + v

proc update*(ctx: var Sha256; data: openArray[char]) =
  require(uint64(data.len) <= high(uint64) div 8 - ctx.total,
          ekLimit, "SHA-256 message length exceeds format bound")
  ctx.total += uint64(data.len)
  for b in data:
    ctx.buffer[ctx.used] = uint8(b)
    inc ctx.used
    if ctx.used == 64:
      ctx.transform
      ctx.used = 0

proc digestBytes*(original: Sha256): string =
  var ctx = original
  let bits = ctx.total * 8
  ctx.buffer[ctx.used] = 0x80
  inc ctx.used
  if ctx.used > 56:
    for i in ctx.used..<64: ctx.buffer[i] = 0
    ctx.transform
    ctx.used = 0
  for i in ctx.used..<56: ctx.buffer[i] = 0
  for i in 0..<8: ctx.buffer[63-i] = uint8((bits shr (i*8)) and 255)
  ctx.transform
  result = newStringOfCap(32)
  for word in ctx.state:
    for shift in countdown(24, 0, 8): result.add char((word shr shift) and 255)

proc hex*(bytes: string): string =
  result = newStringOfCap(bytes.len * 2)
  for b in bytes: result.add toHex(uint8(b), 2).toLowerAscii

proc digest*(ctx: Sha256): string = hex(ctx.digestBytes)

proc sha256*(data: string): string =
  var ctx = initSha256()
  ctx.update(data)
  ctx.digest

proc validId*(id: string): bool =
  if id.len != 64: return false
  for c in id:
    if c notin {'0'..'9', 'a'..'f'}: return false
  true

proc objectId*(kind, data: string): string =
  ## Domain separation keeps a manifest distinct from identically encoded data.
  var ctx = initSha256()
  ctx.update("cairn:1:" & kind & "\0")
  ctx.update(data)
  ctx.digest
