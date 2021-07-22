## Stable error categories for the library and command line. OS exceptions
## retain their original messages at the CLI boundary; format errors carry a
## category so callers do not have to parse human text.
type
  ErrorKind* = enum
    ekInvalid, ekCorrupt, ekMissing, ekConflict, ekUnsafe, ekLimit,
    ekUnrecoverable, ekIo, ekLocked
  CairnError* = object of CatchableError
    kind*: ErrorKind

proc fail*(kind: ErrorKind; message: string) {.noreturn.} =
  var error = newException(CairnError, message)
  error.kind = kind
  raise error

proc require*(condition: bool; kind: ErrorKind; message: string) =
  if not condition:
    fail(kind, message)
