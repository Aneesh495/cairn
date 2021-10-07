import std/unittest
import cairn/[arguments, errors]

suite "strict command line arguments":
  let specs = @[option("count"), option("exclude", repeatable = true), flag("apply")]
  test "options, equals syntax, repeats, and literal operands":
    let args = parseArguments(@["repo", "--count=7", "--exclude", "*.tmp", "--exclude=cache/",
      "--apply", "--", "--literal"], specs)
    check args.operands == @["repo", "--literal"]
    check args.integer("count", 0, 0, 10) == 7
    check args.all("exclude") == @["*.tmp", "cache/"]
    check args.has("apply")
  test "unknown, duplicate, missing, and malformed options reject":
    for input in [@["--unknown"], @["--count"], @["--count", "--apply"],
                  @["--apply=true"], @["--apply", "--apply"], @["-x"], @["--count="]]:
      expect CairnError: discard parseArguments(input, specs)
  test "numeric validation rejects truncation and overflow":
    for value in ["-", "1.0", "1x", "99999999999999999999999999999999", "-1", "11"]:
      let args = parseArguments(@["--count=" & value], specs)
      expect CairnError: discard args.integer("count", 0, 0, 10)
