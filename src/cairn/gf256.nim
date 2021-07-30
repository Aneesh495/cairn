## GF(2^8) with primitive polynomial x^8+x^4+x^3+x^2+1 (0x11d).
## Addition is XOR. Log tables use 0x02 as the primitive element. All coding
## coefficients and serialized geometry are independent of host architecture.
import cairn/errors

func tables(): tuple[exp: array[512, uint8], log: array[256, uint8]] =
  var x = 1
  for i in 0..<255:
    result.exp[i] = uint8(x)
    result.log[x] = uint8(i)
    x = x shl 1
    if (x and 256) != 0: x = x xor 0x11d
  for i in 255..<512: result.exp[i] = result.exp[i-255]

const Tables = tables()

func mul*(a, b: uint8): uint8 =
  if a == 0 or b == 0: return 0
  Tables.exp[int(Tables.log[a]) + int(Tables.log[b])]

proc inverse*(a: uint8): uint8 =
  require(a != 0, ekInvalid, "zero has no field inverse")
  Tables.exp[255 - int(Tables.log[a])]

proc divide*(a, b: uint8): uint8 = mul(a, inverse(b))

func power*(a: uint8; exponent: int): uint8 =
  doAssert exponent >= 0
  if exponent == 0: return 1
  if a == 0: return 0
  Tables.exp[(int(Tables.log[a]) * (exponent mod 255)) mod 255]

proc multiplyAdd*(destination: var string; source: string; coefficient: uint8) =
  require(destination.len == source.len, ekInvalid, "unequal coding buffers")
  if coefficient == 0: return
  if coefficient == 1:
    for i in 0..<source.len:
      destination[i] = char(uint8(destination[i]) xor uint8(source[i]))
  else:
    for i in 0..<source.len:
      destination[i] = char(uint8(destination[i]) xor mul(uint8(source[i]), coefficient))
