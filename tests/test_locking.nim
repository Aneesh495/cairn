import std/[unittest, os, tempfiles]
import cairn/[locking, durable, errors]

suite "repository advisory locks":
  test "shared readers coexist and exclude a writer":
    let root = createTempDir("cairn-lock-", "")
    defer: removeDir(root)
    writeAtomic(root / ".lock", "")
    var first = acquire(root, lmShared)
    var second = acquire(root, lmShared)
    expect CairnError: discard acquire(root, lmExclusive)
    first.release
    second.release
    var writer = acquire(root, lmExclusive)
    expect CairnError: discard acquire(root, lmShared)
    expect CairnError: discard acquire(root, lmExclusive)
    writer.release
    writer.release
    check fileExists(root / ".lock")
  test "exception unwinding releases the lock":
    let root = createTempDir("cairn-lock-", "")
    defer: removeDir(root)
    writeAtomic(root / ".lock", "")
    expect CairnError:
      withRepoLock(root, lmExclusive): fail(ekInvalid, "test")
    withRepoLock(root, lmExclusive): check true
