import std/unittest
import cairn/[gf256, matrix, errors]

proc slowMultiply(a, b: uint8): uint8 =
  var x = int(a)
  var y = int(b)
  var answer = 0
  while y != 0:
    if (y and 1) != 0: answer = answer xor x
    y = y shr 1
    x = x shl 1
    if (x and 256) != 0: x = x xor 0x11d
  uint8(answer)

suite "GF(256) and matrix inversion":
  test "all products match polynomial long multiplication":
    for a in 0..255:
      for b in 0..255:
        check mul(uint8(a), uint8(b)) == slowMultiply(uint8(a), uint8(b))
  test "every nonzero field element has an inverse":
    for a in 1..255:
      check mul(uint8(a), inverse(uint8(a))) == 1
      check divide(uint8(a), uint8(a)) == 1
    expect CairnError: discard inverse(0)
  test "powers agree with repeated multiplication":
    for a in 0..255:
      var acc = 1'u8
      for exponent in 0..32:
        check power(uint8(a), exponent) == acc
        acc = mul(acc, uint8(a))
  test "pivot swaps and input preservation":
    let a: Matrix = @[@[0'u8, 1], @[1'u8, 7]]
    let inv = invert(a)
    check multiply(a, inv) == identity(2)
    check multiply(inv, a) == identity(2)
    check a == @[@[0'u8, 1], @[1'u8, 7]]
  test "ragged, singular, and nonsquare matrices reject":
    expect CairnError: discard invert(@[@[1'u8, 1], @[1'u8, 1]])
    expect CairnError: discard invert(@[@[1'u8, 2]])
    expect CairnError: discard dimensions(@[@[1'u8], @[2'u8, 3]])
