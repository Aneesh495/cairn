## Native entry point. Import cairn/cli from embedders that need the same
## argument and error contracts without terminating their own process.
import std/os
import cairn/cli

when isMainModule:
  quit(run(commandLineParams()))
