{.warning[UnusedImport]: off.} # Importing a test module registers its suites.
import std/unittest
import cairn/errors
import test_binary
import test_sha256
import test_checksums
import test_field
import test_erasure
import test_chunker
import test_compression
import test_capsule
import test_paths
import test_manifest

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
