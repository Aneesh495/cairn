## Strict, bounded JSON building blocks. Persisted metadata uses a canonical
## representation, checked by each decoder after schema validation. Duplicate
## keys, unknown fields, alternate number spellings, and trailing text cannot
## silently change the meaning of an object identity.
import std/[json, sets]
import cairn/[errors, paths]

proc parseBounded*(bytes: string; maximum: int): JsonNode =
  require(validText(bytes, maximum), ekCorrupt, "metadata is oversized or invalid UTF-8")
  var depth = 0
  var quoted = false
  var escaped = false
  for c in bytes:
    if quoted:
      if escaped: escaped = false
      elif c == '\\': escaped = true
      elif c == '"': quoted = false
    else:
      if c == '"': quoted = true
      elif c in {'{', '['}:
        inc depth
        require(depth <= 16, ekLimit, "metadata nesting exceeds 16")
      elif c in {'}', ']'}:
        dec depth
        require(depth >= 0, ekCorrupt, "unbalanced metadata")
  require(not quoted and depth == 0, ekCorrupt, "incomplete metadata")
  try:
    result = parseJson(bytes)
  except CatchableError as e:
    fail(ekCorrupt, "invalid JSON metadata: " & e.msg)

proc fields*(node: JsonNode; expected: openArray[string]) =
  require(node.kind == JObject and node.len == expected.len,
          ekCorrupt, "metadata object has unexpected fields")
  let allowed = toHashSet(expected)
  for key, value in node:
    discard value
    require(key in allowed, ekCorrupt, "unknown metadata field: " & key)

proc stringField*(node: JsonNode; key: string; maximum: int): string =
  require(node.hasKey(key) and node[key].kind == JString,
          ekCorrupt, "expected string field: " & key)
  result = node[key].getStr
  require(validText(result, maximum), ekCorrupt, "invalid string field: " & key)

proc intField*(node: JsonNode; key: string; minimum, maximum: int64): int64 =
  require(node.hasKey(key) and node[key].kind == JInt,
          ekCorrupt, "expected integer field: " & key)
  result = node[key].getBiggestInt
  require(result >= minimum and result <= maximum, ekCorrupt,
          "integer field outside bounds: " & key)

proc arrayField*(node: JsonNode; key: string; maximum: int): JsonNode =
  require(node.hasKey(key) and node[key].kind == JArray and node[key].len <= maximum,
          ekCorrupt, "invalid array field: " & key)
  node[key]

proc canonical*(bytes, encoded: string) =
  require(bytes == encoded, ekCorrupt, "metadata is not in canonical version-1 encoding")
