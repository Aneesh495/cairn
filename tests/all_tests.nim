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
import test_durable
import test_locking
import test_repository
import test_store
import test_references
import test_backup
import test_restore
import test_damage
import test_repair
import test_planner
import test_salvage
import test_diff
import test_retention
import test_gc
import test_assemble
import test_glob
import test_bundle

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
