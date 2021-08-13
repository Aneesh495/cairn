## Archive paths are portable UTF-8 relative names. File contents remain
## arbitrary bytes. Reject ambiguous separators and traversal before joining
## any manifest-controlled path to an operating-system directory.
import std/[os, strutils, unicode]
import cairn/[errors, limits]

proc validText*(text: string; maximum: int): bool =
  text.len <= maximum and '\0' notin text and validateUtf8(text) == -1

proc validatePath*(path: string; allowRoot = false) =
  if allowRoot and path == ".": return
  require(path.len > 0 and validText(path, MaxPathBytes), ekUnsafe,
          "archive path must be nonempty UTF-8 without NUL")
  require(not path.isAbsolute and '\\' notin path and ':' notin path,
          ekUnsafe, "archive path must use relative POSIX components")
  let components = path.split('/')
  require(components.len <= MaxDepth, ekLimit, "archive path exceeds depth limit")
  for component in components:
    require(component.len > 0 and component notin [".", ".."],
            ekUnsafe, "archive path contains traversal or empty component")

proc validateLabel*(label: string) =
  require(label.len in 1..MaxLabelBytes, ekInvalid, "snapshot label must be 1..80 bytes")
  for c in label:
    require(c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'},
            ekInvalid, "snapshot label permits only letters, digits, hyphen, underscore")

proc validateLink*(path, target: string) =
  path.validatePath
  require(target.len > 0 and validText(target, MaxPathBytes) and
          not target.isAbsolute and '\\' notin target and ':' notin target,
          ekUnsafe, "symbolic link target must be relative UTF-8")
  var depth = path.split('/').len - 1
  for component in target.split('/'):
    if component == "..": dec depth
    elif component notin ["", "."]: inc depth
    require(depth >= 0, ekUnsafe, "symbolic link target escapes restored tree")

proc existsAny*(path: string): bool =
  fileExists(path) or dirExists(path) or symlinkExists(path)

proc assertNoSymlinks*(path: string) =
  ## This protects against pre-existing links. Hostile processes concurrently
  ## changing parent directories are outside the local repository threat model.
  let absolute = absolutePath(path).normalizedPath
  var current = "/"
  for part in absolute.split('/'):
    if part.len == 0: continue
    current = current / part
    require(not symlinkExists(current), ekUnsafe, "symlink in managed path: " & current)

proc managedPath*(root, relative: string): string =
  validatePath(relative)
  # Resolve the caller-selected root once. macOS commonly exposes temporary
  # roots through /var -> /private/var. Links below that root remain forbidden.
  require(dirExists(root), ekMissing, "managed root does not exist: " & root)
  var current = expandFilename(root)
  for component in relative.split('/'):
    current = current / component
    require(not symlinkExists(current), ekUnsafe, "symlink in managed path: " & current)
  result = current

proc isWithin*(child, parent: string): bool =
  let c = absolutePath(child).normalizedPath
  let p = absolutePath(parent).normalizedPath
  c == p or c.startsWith(p & "/") or p == "/"
