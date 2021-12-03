version = "0.1.0"
author = "Aneesh Krishna"
description = "Damage-aware, deduplicated archives with index-free recovery"
license = "MIT"
srcDir = "src"
binDir = "bin"
bin = @["cairn"]
requires "nim >= 2.2.6"
skipDirs = @["tests", "docs", "tools", "bench", "evidence", "examples", ".github"]

task test, "Run the checked unit and integration suites":
  exec "make test"

task verify, "Run independent archive verification":
  exec "make verify"
