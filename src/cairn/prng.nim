## SplitMix64 is deterministic test and chunk-table machinery. It is never
## used for cryptographic keys, authentication, or unpredictable identifiers.
type Prng* = object
  state*: uint64

proc next*(rng: var Prng): uint64 =
  rng.state += 0x9e3779b97f4a7c15'u64
  var z = rng.state
  z = (z xor (z shr 30)) * 0xbf58476d1ce4e5b9'u64
  z = (z xor (z shr 27)) * 0x94d049bb133111eb'u64
  z xor (z shr 31)

proc bounded*(rng: var Prng; bound: int): int =
  doAssert bound > 0
  int(rng.next mod uint64(bound))

proc bytes*(rng: var Prng; count: int): string =
  result = newString(count)
  var word = 0'u64
  for i in 0..<count:
    if i mod 8 == 0: word = rng.next
    result[i] = char((word shr ((i mod 8)*8)) and 255)

proc shuffle*[T](rng: var Prng; values: var seq[T]) =
  for i in countdown(values.high, 1):
    let j = rng.bounded(i+1)
    swap(values[i], values[j])
