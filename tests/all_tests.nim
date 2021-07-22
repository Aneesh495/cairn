import std/unittest
import cairn/errors

suite "typed errors":
  test "category survives the exception boundary":
    try:
      fail(ekCorrupt, "capsule checksum")
    except CairnError as e:
      check e.kind == ekCorrupt
      check e.msg == "capsule checksum"
  test "requirements reject a false predicate":
    expect CairnError:
      require(false, ekInvalid, "invalid")
