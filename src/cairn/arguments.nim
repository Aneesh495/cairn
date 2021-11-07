## Small strict argument parser. Each command declares its own accepted
## options, so misspellings and duplicate flags cannot silently alter a backup
## or a maintenance operation. '--' makes subsequent operands literal.
import std/[tables, strutils]
import cairn/errors

type
  OptionSpec* = object
    name*: string
    value*: bool
    repeatable*: bool
  Arguments* = object
    operands*: seq[string]
    options*: Table[string, seq[string]]

proc flag*(name: string): OptionSpec = OptionSpec(name: name)
proc option*(name: string; repeatable = false): OptionSpec =
  OptionSpec(name: name, value: true, repeatable: repeatable)

proc parseArguments*(args: seq[string]; specs: seq[OptionSpec]): Arguments =
  result.options = initTable[string, seq[string]]()
  var known = initTable[string, OptionSpec]()
  for spec in specs:
    require(spec.name.len > 0 and not known.hasKey(spec.name), ekInvalid, "invalid command option schema")
    known[spec.name] = spec
  var at = 0
  var literal = false
  while at < args.len:
    let arg = args[at]
    inc at
    if not literal and arg == "--":
      literal = true
      continue
    if literal or not arg.startsWith("-") or arg == "-":
      result.operands.add arg
      continue
    require(arg.startsWith("--") and arg.len > 2, ekInvalid, "expected a long option, got " & arg)
    let equals = arg.find('=')
    let key = if equals < 0: arg[2..^1] else: arg[2..<equals]
    require(known.hasKey(key), ekInvalid, "unknown option --" & key)
    let spec = known[key]
    require(spec.repeatable or not result.options.hasKey(key), ekInvalid, "duplicate option --" & key)
    var value = "true"
    if spec.value:
      if equals >= 0: value = arg[equals+1..^1]
      else:
        require(at < args.len and not args[at].startsWith("--"), ekInvalid, "missing value for --" & key)
        value = args[at]
        inc at
      require(value.len > 0, ekInvalid, "empty value for --" & key)
    else: require(equals < 0, ekInvalid, "flag --" & key & " does not take a value")
    result.options.mgetOrPut(key, @[]).add value

proc has*(args: Arguments; key: string): bool = args.options.hasKey(key)
proc get*(args: Arguments; key: string; fallback = ""): string =
  if args.options.hasKey(key): args.options[key][0] else: fallback
proc all*(args: Arguments; key: string): seq[string] = args.options.getOrDefault(key)

proc integer*(args: Arguments; key: string; fallback, minimum, maximum: int64): int64 =
  if not args.has(key): return fallback
  let value = args.get(key)
  require(value.len <= 20 and value.len > 0, ekInvalid, "invalid integer for --" & key)
  for i, c in value:
    require(c in {'0'..'9'} or (i == 0 and c == '-'), ekInvalid, "invalid integer for --" & key)
  try: result = parseBiggestInt(value)
  except ValueError: fail(ekInvalid, "integer out of range for --" & key)
  require(result >= minimum and result <= maximum, ekInvalid, "integer outside bounds for --" & key)

proc arity*(args: Arguments; count: int) =
  require(args.operands.len == count, ekInvalid, "expected " & $count & " operands, got " &
      $args.operands.len)
