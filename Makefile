NIM ?= nim
NIMFLAGS ?=

.PHONY: all build test test-release verify clean demo bench
all: build

build:
	@mkdir -p bin build
	$(NIM) c --hints:off $(NIMFLAGS) -d:release -o:bin/cairn src/cairn.nim

test:
	@mkdir -p build
	$(NIM) c -r --hints:off $(NIMFLAGS) -o:build/tests tests/all_tests.nim

test-release:
	@mkdir -p build
	$(NIM) c -r --hints:off $(NIMFLAGS) -d:release -o:build/tests-release tests/all_tests.nim

verify: build test test-release
	python3 tools/verify.py

demo: build
	./bin/cairn demo .runtime/demo

bench: build
	$(NIM) c -r --hints:off -d:release -o:build/bench bench/bench.nim

clean:
	rm -rf bin build nimcache
