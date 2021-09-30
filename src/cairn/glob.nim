## Iterative, bounded path globs. '*' and '?' stay within one component; '**'
## crosses separators; '**/' also matches zero directories. Matching is over
## UTF-8 bytes so archive names are never normalized or rewritten.
import std/strutils
import cairn/[errors, paths]

type
  TokenKind = enum
    tkLiteral, tkAny, tkStar, tkGlobStar, tkGlobDirectory
  Token = object
    kind: TokenKind
    literal: char
  IgnoreRule* = object
    pattern*: string
    reinstate*: bool
    directoryOnly*: bool

proc compileGlob(pattern: string): seq[Token] =
  var at = 0
  while at < pattern.len:
    if pattern[at] == '*':
      if at+1 < pattern.len and pattern[at+1] == '*':
        at += 2
        if at < pattern.len and pattern[at] == '/':
          result.add Token(kind: tkGlobDirectory)
          inc at
        else: result.add Token(kind: tkGlobStar)
      else:
        result.add Token(kind: tkStar)
        inc at
    elif pattern[at] == '?':
      result.add Token(kind: tkAny)
      inc at
    else:
      result.add Token(kind: tkLiteral, literal: pattern[at])
      inc at

proc globMatch*(pattern, path: string): bool =
  require(validText(pattern, 512), ekInvalid, "glob exceeds 512 UTF-8 bytes or contains NUL")
  var previous = newSeq[bool](path.len+1)
  previous[0] = true
  for token in compileGlob(pattern):
    var current = newSeq[bool](path.len+1)
    case token.kind
    of tkLiteral, tkAny:
      for j in 1..path.len:
        current[j] = previous[j-1] and
          (if token.kind == tkAny: path[j-1] != '/' else: path[j-1] == token.literal)
    of tkStar, tkGlobStar:
      current[0] = previous[0]
      for j in 1..path.len:
        current[j] = previous[j] or (current[j-1] and
          (token.kind == tkGlobStar or path[j-1] != '/'))
    of tkGlobDirectory:
      current[0] = previous[0]
      var prefix = previous[0]
      for j in 1..path.len:
        current[j] = previous[j] or (path[j-1] == '/' and prefix)
        prefix = prefix or previous[j]
    previous = move(current)
  previous[path.len]

proc parseRules*(patterns: seq[string]): seq[IgnoreRule] =
  require(patterns.len <= 256, ekLimit, "at most 256 exclusion rules are supported")
  for original in patterns:
    require(original.len > 0 and validText(original, 512), ekInvalid, "invalid exclusion rule")
    var pattern = original
    var rule: IgnoreRule
    if pattern[0] == '!':
      rule.reinstate = true
      pattern = pattern[1..^1]
    require(pattern.len > 0, ekInvalid, "empty exclusion pattern")
    if pattern[^1] == '/':
      rule.directoryOnly = true
      pattern.setLen(pattern.len-1)
    require(pattern.len > 0, ekInvalid, "cannot exclude the entire source root")
    if pattern[0] == '/': pattern = pattern[1..^1]
    elif '/' notin pattern: pattern = "**/" & pattern
    require(pattern.len > 0 and '\\' notin pattern and ':' notin pattern,
            ekInvalid, "exclusion rule must use POSIX separators")
    for component in pattern.split('/'):
      require(component notin ["", ".", ".."], ekInvalid, "ambiguous exclusion pattern")
    rule.pattern = pattern
    result.add rule

proc excluded*(rules: seq[IgnoreRule]; path: string; directory: bool): bool =
  for rule in rules:
    if (not rule.directoryOnly or directory) and globMatch(rule.pattern, path):
      result = not rule.reinstate
