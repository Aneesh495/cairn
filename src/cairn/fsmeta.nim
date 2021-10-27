## Source identity and portable metadata. Capture ctime as well as mtime and
## inode identity to detect replacements and in-place edits during a backup.
import std/[os, posix, times]
import cairn/errors

type SourceStamp* = object
  device*: uint64
  inode*: uint64
  size*: int64
  mode*: int
  kind*: PathComponent
  mtimeNs*: int64
  ctimeNs*: int64

proc timeNs*(time: times.Time): int64 =
  let seconds = time.toUnix
  require(seconds >= low(int64) div 1_000_000_000 + 1 and
          seconds <= high(int64) div 1_000_000_000 - 1,
          ekLimit, "timestamp is outside the nanosecond format range")
  seconds * 1_000_000_000 + int64(time.nanosecond)

proc fromNs*(ns: int64): times.Time =
  var seconds = ns div 1_000_000_000
  var fraction = ns mod 1_000_000_000
  if fraction < 0:
    dec seconds
    fraction += 1_000_000_000
  fromUnix(seconds) + initDuration(nanoseconds = fraction)

proc stamp*(info: Stat): SourceStamp =
  result.device = uint64(info.st_dev)
  result.inode = uint64(info.st_ino)
  result.size = int64(info.st_size)
  result.mode = int(info.st_mode) and 0o777
  require(info.st_mtim.tv_nsec >= 0 and info.st_mtim.tv_nsec < 1_000_000_000 and
          info.st_ctim.tv_nsec >= 0 and info.st_ctim.tv_nsec < 1_000_000_000,
          ekInvalid, "filesystem supplied an invalid nanosecond timestamp")
  result.mtimeNs = timeNs(fromUnix(int64(info.st_mtim.tv_sec)) +
    initDuration(nanoseconds = int64(info.st_mtim.tv_nsec)))
  result.ctimeNs = timeNs(fromUnix(int64(info.st_ctim.tv_sec)) +
    initDuration(nanoseconds = int64(info.st_ctim.tv_nsec)))
  if S_ISREG(info.st_mode): result.kind = pcFile
  elif S_ISDIR(info.st_mode): result.kind = pcDir
  elif S_ISLNK(info.st_mode): result.kind = pcLinkToFile
  else: fail(ekUnsafe, "special files cannot be archived")

proc stamp*(path: string): SourceStamp =
  var info: Stat
  require(posix.lstat(path.cstring, info) == 0, ekIo, "cannot stat source: " & path)
  stamp(info)

proc permissions*(mode: int): set[FilePermission] =
  const Bits = [(0o400, fpUserRead), (0o200, fpUserWrite), (0o100, fpUserExec),
                (0o040, fpGroupRead), (0o020, fpGroupWrite), (0o010, fpGroupExec),
                (0o004, fpOthersRead), (0o002, fpOthersWrite), (0o001, fpOthersExec)]
  for (bit, permission) in Bits:
    if (mode and bit) != 0: result.incl permission

proc applyMetadata*(path: string; mode: int; mtimeNs: int64) =
  setFilePermissions(path, permissions(mode))
  setLastModificationTime(path, fromNs(mtimeNs))
