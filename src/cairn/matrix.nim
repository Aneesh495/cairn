## Small, checked matrices over GF(256). Geometry is capped at 32 shards, so
## Gauss-Jordan elimination is cheap relative to reading capsule payloads.
import cairn/[errors, gf256, limits]

type Matrix* = seq[seq[uint8]]

proc dimensions*(a: Matrix): tuple[rows, cols: int] =
  require(a.len > 0 and a.len <= MaxShards, ekInvalid, "invalid matrix rows")
  let cols = a[0].len
  require(cols > 0 and cols <= MaxShards, ekInvalid, "invalid matrix columns")
  for row in a:
    require(row.len == cols, ekInvalid, "ragged matrix")
  (a.len, cols)

proc zeros*(rows, cols: int): Matrix =
  require(rows > 0 and rows <= MaxShards and cols > 0 and cols <= MaxShards,
          ekInvalid, "matrix dimension exceeds coding limit")
  result = newSeq[seq[uint8]](rows)
  for i in 0..<rows: result[i] = newSeq[uint8](cols)

proc identity*(size: int): Matrix =
  result = zeros(size, size)
  for i in 0..<size: result[i][i] = 1

proc multiply*(a, b: Matrix): Matrix =
  let (ar, ac) = a.dimensions
  let (br, bc) = b.dimensions
  require(ac == br, ekInvalid, "incompatible matrix dimensions")
  result = zeros(ar, bc)
  for row in 0..<ar:
    for col in 0..<bc:
      for k in 0..<ac:
        result[row][col] = result[row][col] xor mul(a[row][k], b[k][col])

proc invert*(a: Matrix): Matrix =
  let (rows, cols) = a.dimensions
  require(rows == cols, ekInvalid, "cannot invert a nonsquare matrix")
  # Explicit copying prevents aliasing the caller's input under any memory
  # manager. Row swaps apply to both halves of the augmented matrix.
  var left = zeros(rows, cols)
  for i in 0..<rows:
    for j in 0..<cols: left[i][j] = a[i][j]
  result = identity(rows)
  for pivot in 0..<rows:
    var selected = pivot
    while selected < rows and left[selected][pivot] == 0: inc selected
    require(selected < rows, ekInvalid, "singular field matrix")
    if selected != pivot:
      swap(left[selected], left[pivot])
      swap(result[selected], result[pivot])
    let scale = inverse(left[pivot][pivot])
    for col in 0..<cols:
      left[pivot][col] = mul(left[pivot][col], scale)
      result[pivot][col] = mul(result[pivot][col], scale)
    for row in 0..<rows:
      if row == pivot: continue
      let factor = left[row][pivot]
      if factor == 0: continue
      for col in 0..<cols:
        left[row][col] = left[row][col] xor mul(factor, left[pivot][col])
        result[row][col] = result[row][col] xor mul(factor, result[pivot][col])
