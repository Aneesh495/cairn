## POSIX durability boundary. Writers stage on the destination filesystem,
## flush file contents, publish the name, and flush its parent directory.
## Immutable publication uses link(2), which cannot replace an existing name.
when not defined(posix):
  {.error: "Cairn currently requires POSIX macOS or Linux".}

import std/[os, posix]
import cairn/errors

var NoFollow* {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
proc renameNative*(source, destination: cstring): cint {.importc: "rename", header: "<stdio.h>".}

var stageCounter = 0

proc systemFailure(operation, path: string) {.noreturn.} =
  let code = osLastError()
  fail(ekIo, operation & " " & path & ": " & osErrorMsg(code))

proc crashPoint*(name: string) =
  ## Explicit fault-injection hook for subprocess crash tests. Normal runs do
  ## not set CAIRN_CRASH_AT. SIGKILL prevents finally blocks from masking a
  ## durability defect with graceful cleanup.
  if getEnv("CAIRN_CRASH_AT") == name:
    discard posix.kill(posix.getpid(), SIGKILL)

proc syncFd*(fd: cint; path: string) =
  while posix.fsync(fd) != 0:
    if errno != EINTR: systemFailure("fsync", path)

proc syncDirectory*(path: string) =
  let fd = posix.open(path.cstring, O_RDONLY or NoFollow)
  if fd < 0: systemFailure("open directory", path)
  defer: discard posix.close(fd)
  var info: Stat
  if posix.fstat(fd, info) != 0: systemFailure("stat directory", path)
  require(S_ISDIR(info.st_mode), ekUnsafe, "not a directory: " & path)
  syncFd(fd, path)

proc readBounded*(path: string; maximum: int): string =
  require(maximum >= 0, ekInvalid, "negative read bound")
  let fd = posix.open(path.cstring, O_RDONLY or NoFollow or O_NONBLOCK)
  if fd < 0: systemFailure("open", path)
  defer: discard posix.close(fd)
  var info: Stat
  if posix.fstat(fd, info) != 0: systemFailure("fstat", path)
  require(S_ISREG(info.st_mode), ekUnsafe, "managed file is not regular: " & path)
  require(info.st_size >= 0 and uint64(info.st_size) <= uint64(maximum),
          ekLimit, "managed file exceeds read bound: " & path)
  result = newString(int(info.st_size))
  var at = 0
  while at < result.len:
    let count = posix.read(fd, addr result[at], result.len-at)
    if count < 0:
      if errno == EINTR: continue
      systemFailure("read", path)
    require(count > 0, ekCorrupt, "managed file truncated while reading: " & path)
    at += count
  var extra: char
  let count = posix.read(fd, addr extra, 1)
  require(count == 0, ekCorrupt, "managed file grew while reading: " & path)

proc writeAll*(fd: cint; data: string; path: string) =
  var at = 0
  while at < data.len:
    let count = posix.write(fd, unsafeAddr data[at], data.len-at)
    if count < 0:
      if errno == EINTR: continue
      systemFailure("write", path)
    require(count > 0, ekIo, "zero-length write: " & path)
    at += count

proc privateStage*(parent: string): tuple[path: string, fd: cint] =
  for attempt in 0..<1000:
    inc stageCounter
    let path = parent / (".cairn-stage-" & $posix.getpid() & "-" & $stageCounter)
    let fd = posix.open(path.cstring, O_WRONLY or O_CREAT or O_EXCL or NoFollow, Mode(0o600))
    if fd >= 0: return (path, fd)
    if errno != EEXIST: systemFailure("create stage", path)
  fail(ekConflict, "cannot allocate a private staging filename")

proc writeAtomic*(path, data: string; replace = false) =
  let parent = parentDir(path)
  require(dirExists(parent), ekMissing, "publication parent does not exist: " & parent)
  require(not symlinkExists(path), ekUnsafe, "refusing a symlink destination: " & path)
  let stage = privateStage(parent)
  var open = true
  defer:
    if open: discard posix.close(stage.fd)
    if fileExists(stage.path): removeFile(stage.path)
  writeAll(stage.fd, data, stage.path)
  crashPoint("file-written")
  syncFd(stage.fd, stage.path)
  crashPoint("file-synced")
  if posix.close(stage.fd) != 0: systemFailure("close", stage.path)
  open = false
  if replace:
    if renameNative(stage.path.cstring, path.cstring) != 0: systemFailure("rename", path)
  else:
    if posix.link(stage.path.cstring, path.cstring) != 0:
      if errno == EEXIST: fail(ekConflict, "immutable destination already exists: " & path)
      systemFailure("publish", path)
    removeFile(stage.path)
  crashPoint("file-published")
  syncDirectory(parent)
  crashPoint("directory-synced")

proc ensureDirectory*(path: string) =
  require(not symlinkExists(path), ekUnsafe, "directory is a symlink: " & path)
  if dirExists(path): return
  let parent = parentDir(path)
  require(dirExists(parent), ekMissing, "directory parent is missing: " & parent)
  if posix.mkdir(path.cstring, Mode(0o700)) != 0:
    if errno != EEXIST: systemFailure("mkdir", path)
    require(dirExists(path) and not symlinkExists(path), ekUnsafe, "unsafe directory race")
  syncDirectory(parent)

proc removeDurable*(path: string) =
  require(not symlinkExists(path), ekUnsafe, "refusing to unlink managed symlink")
  removeFile(path)
  syncDirectory(parentDir(path))
