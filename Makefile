NIM ?= tools/nim
NIMFLAGS ?=

.PHONY: all build test test-release campaign verify clean demo bench check acceptance verify-evidence replay-evidence bootstrap
all: build

build:
	@mkdir -p bin build
	$(NIM) c --nimcache:build/nimcache/app --hints:off $(NIMFLAGS) -d:release -o:bin/cairn src/cairn.nim

test:
	@mkdir -p build/evidence
	$(NIM) c --nimcache:build/nimcache/unit-debug --hints:off $(NIMFLAGS) -o:build/tests tests/all_tests.nim
	python3 tools/capture.py build/evidence/unit-debug.log ./build/tests

test-release:
	@mkdir -p build/evidence
	$(NIM) c --nimcache:build/nimcache/unit-release --hints:off $(NIMFLAGS) -d:release -o:build/tests-release tests/all_tests.nim
	python3 tools/capture.py build/evidence/unit-release.log ./build/tests-release

campaign:
	@mkdir -p build/evidence
	$(NIM) c --nimcache:build/nimcache/campaign --hints:off $(NIMFLAGS) -d:release -o:build/campaign tests/campaign.nim
	./build/campaign > build/evidence/campaign.json
	@cat build/evidence/campaign.json

verify: build test test-release campaign
	python3 tools/verify.py

check: verify

acceptance: verify
	python3 tools/evidence.py freeze

verify-evidence:
	python3 tools/evidence.py verify

replay-evidence:
	python3 tools/evidence.py replay

demo: build
	@mkdir -p .runtime
	./bin/cairn demo .runtime/demo

bench: build
	$(NIM) c -r --nimcache:build/nimcache/bench --hints:off -d:release -o:build/bench bench/bench.nim

clean:
	rm -rf bin build nimcache

bootstrap:
	python3 tools/bootstrap.py --bootstrap
