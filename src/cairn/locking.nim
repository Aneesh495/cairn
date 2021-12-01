## Advisory flock locks survive process termination without stale-lock
## guessing. The lock inode is permanent and must never be unlinked while a
## repository exists. High-level workflows own the lock; low-level storage
## helpers rely on their caller to keep that lock for the complete operation.
import std/posix
import cairn/[durable, errors, paths]

type
  LockMode* = enum
    lmShared, lmExclusive
  RepoLock* = object
    fd: cint
    held: bool

var
  LockShared {.importc: "LOCK_SH", header: "<sys/file.h>".}: cint
  LockExclusive {.importc: "LOCK_EX", header: "<sys/file.h>".}: cint
  LockNonblock {.importc: "LOCK_NB", header: "<sys/file.h>".}: cint
  LockUnlock {.importc: "LOCK_UN", header: "<sys/file.h>".}: cint

proc flockNative(fd, operation: cint): cint {.importc: "flock", header: "<sys/file.h>".}

proc acquire*(root: string; mode: LockMode): RepoLock =
  let path = managedPath(root, ".lock")
  let fd = posix.open(path.cstring, O_RDWR or NoFollow or O_NONBLOCK)
  require(fd >= 0, ekIo, "cannot open repository lock: " & path)
  var info: Stat
  if posix.fstat(fd, info) != 0 or not S_ISREG(info.st_mode):
    discard posix.close(fd)
    fail(ekUnsafe, "repository lock is not a regular file")
  let operation = (if mode == lmShared: LockShared else: LockExclusive) or LockNonblock
  if flockNative(fd, operation) != 0:
    discard posix.close(fd)
    fail(ekLocked, "repository is in use by another operation")
  RepoLock(fd: fd, held: true)

proc release*(lock: var RepoLock) =
  if lock.held:
    discard flockNative(lock.fd, LockUnlock)
    discard posix.close(lock.fd)
    lock.held = false

template withRepoLock*(root: string; mode: LockMode; body: untyped) =
  block:
    var repositoryLock = acquire(root, mode)
    try:
      body
    finally:
      repositoryLock.release
