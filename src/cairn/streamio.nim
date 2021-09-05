## Streaming counterpart of immutable publication. A staged file is private
## until finish succeeds. Call abort in a finally block even after finish;
## cleanup then becomes an idempotent no-op.
import std/[os, posix]
import cairn/[durable, errors, fsmeta, paths]

type StagedFile* = ref object
  destination: string
  temporary: string
  fd: cint
  open: bool
  published: bool

proc beginFile*(destination: string): StagedFile =
  require(not existsAny(destination), ekConflict, "restore destination already exists")
  let stage = privateStage(parentDir(destination))
  StagedFile(destination: destination, temporary: stage.path, fd: stage.fd, open: true)

proc append*(file: StagedFile; bytes: string) =
  require(file.open and not file.published, ekInvalid, "staged file is closed")
  writeAll(file.fd, bytes, file.temporary)

proc finish*(file: StagedFile; mode: int; mtimeNs: int64) =
  require(file.open and not file.published, ekInvalid, "staged file is closed")
  applyMetadata(file.temporary, mode, mtimeNs)
  syncFd(file.fd, file.temporary)
  require(posix.close(file.fd) == 0, ekIo, "cannot close staged restore file")
  file.open = false
  require(posix.link(file.temporary.cstring, file.destination.cstring) == 0,
          ekConflict, "cannot publish restored file")
  file.published = true
  removeFile(file.temporary)
  syncDirectory(parentDir(file.destination))

proc abort*(file: StagedFile) =
  if file.isNil: return
  if file.open:
    discard posix.close(file.fd)
    file.open = false
  if fileExists(file.temporary): removeFile(file.temporary)
