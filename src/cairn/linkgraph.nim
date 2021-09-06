## Resolve manifest symlink chains without touching the filesystem. A lexical
## check on each target alone is insufficient: a link to a parent can make a
## later '..' escape even when the target string appears to stay inside.
import std/[tables, deques, strutils]
import cairn/[errors, paths]

proc resolveLink*(path: string; links: Table[string, string]): string =
  var pending = initDeque[string]()
  for component in path.split('/'): pending.addLast(component)
  var resolved: seq[string]
  var followed = 0
  while pending.len > 0:
    let component = pending.popFirst
    case component
    of "", ".": discard
    of "..":
      require(resolved.len > 0, ekUnsafe, "symbolic link chain escapes restored tree: " & path)
      resolved.setLen(resolved.len-1)
    else:
      resolved.add component
      let candidate = resolved.join("/")
      if links.hasKey(candidate):
        inc followed
        require(followed <= 40, ekUnsafe, "cyclic or excessive symbolic link chain: " & path)
        resolved.setLen(resolved.len-1)
        let target = links[candidate].split('/')
        for i in countdown(target.high, 0): pending.addFirst(target[i])
  result = resolved.join("/")

proc validateLinkGraph*(links: Table[string, string]) =
  for path, target in links:
    validateLink(path, target)
    discard resolveLink(path, links)
