import std/[unittest, strutils]
import cairn/sha256

suite "SHA-256 known answers":
  test "FIPS vectors":
    check sha256("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    check sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    check sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
    check sha256(repeat('a', 1_000_000)) ==
      "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
  test "incremental and one-shot hashes agree at padding boundaries":
    for length in 0..257:
      let data = repeat('x', length)
      for stride in [1, 7, 55, 64, 65]:
        var ctx = initSha256()
        var start = 0
        while start < data.len:
          let stop = min(start + stride, data.len)
          ctx.update(data.toOpenArray(start, stop-1))
          start = stop
        check ctx.digest == sha256(data)
        check ctx.digest == ctx.digest
  test "object domains and hex validation":
    check objectId("data", "x") != objectId("manifest", "x")
    check validId(sha256("x"))
    check not validId(repeat('A', 64))
    check not validId("../x")
