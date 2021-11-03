#!/usr/bin/env python3
"""Preserve test output without losing the child process's exit status."""
import pathlib
import subprocess
import sys
path = pathlib.Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
with path.open('wb') as output:
    process = subprocess.Popen(sys.argv[2:], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    for line in process.stdout:
        output.write(line)
        output.flush()
        sys.stdout.buffer.write(line)
        sys.stdout.buffer.flush()
    raise SystemExit(process.wait())
