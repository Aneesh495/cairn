## Source identity and portable metadata. Capture ctime as well as mtime and
## inode identity to detect replacements and in-place edits during a backup.
import std/[os, posix, times]
import cairn/[errors, durable]

var UtimeOmit {.importc: "UTIME_OMIT", header: "<sys/stat.h>".}: clong
proc futimensNative(fd: cint; values: ptr Timespec): cint {.
  importc: "futimens", header: "<sys/stat.h>".}

type SourceStamp* = object
  device*: uint64
  inode*: uint64
  size*: int64
  mode*: int
  kind*: PathComponent
  mtimeNs*: int64
  ctimeNs*: int64

proc timeNs*(time: times.Time): int64 =
  const Billion = 1_000_000_000'i64
  const MinimumSecond = low(int64) div Billion - 1
  const MinimumFraction = Billion + low(int64) mod Billion
  const MaximumSecond = high(int64) div Billion
  const MaximumFraction = high(int64) mod Billion
  let seconds = time.toUnix
  let fraction = int64(time.nanosecond)
  require(seconds >= MinimumSecond and seconds <= MaximumSecond,
    ekLimit, "timestamp is outside the nanosecond format range")
  if seconds == MinimumSecond:
    require(fraction >= MinimumFraction, ekLimit, "timestamp precedes the nanosecond format range")
    # Multiplying the floor second here would underflow before adding the
    # positive fraction. Offset from the exact representable minimum instead.
    return low(int64) + (fraction-MinimumFraction)
  if seconds == MaximumSecond:
    require(fraction <= MaximumFraction, ekLimit, "timestamp exceeds the nanosecond format range")
  seconds * Billion + fraction

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

proc applyMetadata*(fd: cint; mode: int; mtimeNs: int64) =
  ## Descriptor-based nanosecond timestamps avoid the standard utimes wrapper's
  ## microsecond truncation. Verify the host actually preserved the metadata.
  require(mode in 0..0o777, ekInvalid, "invalid restored permission bits")
  let time = fromNs(mtimeNs)
  var values = [Timespec(tv_sec: posix.Time(0), tv_nsec: UtimeOmit),
    Timespec(tv_sec: posix.Time(time.toUnix), tv_nsec: clong(time.nanosecond))]
  require(posix.fchmod(fd, Mode(mode)) == 0, ekIo, "cannot set restored permissions")
  require(futimensNative(fd, addr values[0]) == 0, ekIo, "cannot set nanosecond modification time")
  var info: Stat
  require(posix.fstat(fd, info) == 0, ekIo, "cannot verify restored metadata")
  let actual = stamp(info)
  require(actual.mode == mode and actual.mtimeNs == mtimeNs, ekIo,
    "destination filesystem did not preserve stored permissions or timestamp precision")

proc applyMetadata*(path: string; mode: int; mtimeNs: int64) =
  let fd = posix.open(path.cstring, O_RDONLY or NoFollow or O_NONBLOCK)
  require(fd >= 0, ekIo, "cannot open metadata destination")
  defer: discard posix.close(fd)
  var info: Stat
  require(posix.fstat(fd, info) == 0 and (S_ISREG(info.st_mode) or S_ISDIR(info.st_mode)),
    ekUnsafe, "metadata destination must be a regular file or directory")
  applyMetadata(fd, mode, mtimeNs)
