# The fuzzer needs a Swift 6.2 or later toolchain from swift.org.
# The downloadable release toolchains provide the `swift` alias.
TOOLCHAINS ?= swift

all:
	echo nothing defined by default

regen-unicode-width:
	python3 scripts/regen_unicode_width_data.py

check-unicode-width:
	python3 scripts/regen_unicode_width_data.py --check

benchmark-unicode-width:
	swiftc -O Sources/SwiftTerm/Utilities.swift Sources/SwiftTerm/UnicodeWidthData.swift Benchmarks/UnicodeColumnWidthBenchmark.swift -o /tmp/swiftterm-unicode-width-benchmark
	/tmp/swiftterm-unicode-width-benchmark

build-fuzzer:
	xcrun --toolchain $(TOOLCHAINS) swift build --product SwiftTermFuzz -Xswiftc "-sanitize=fuzzer" -Xswiftc "-parse-as-library"

run-fuzzer:
	./.build/debug/SwiftTermFuzz ../SwiftTermFuzzerCorpus -rss_limit_mb=40480 -jobs=12

run-fuzzer-ghostty:
	swift test --filter GhosttyFuzzCorpusTests

run-fuzzer-ghostty2:
	swift test --filter GhosttyFuzz

# The esctest2 commit that the tests and Fixtures/esctest-known-good.txt use.
ESCTEST_REPO = https://github.com/ThomasDickey/esctest2.git
ESCTEST_COMMIT = 2798f12149a19c3295e9b4853ab2da4b2eff1b2b

clone-esctest:
	@if [ ! -d esctest ]; then git clone $(ESCTEST_REPO) esctest; fi
	cd esctest && git remote set-url origin $(ESCTEST_REPO) && \
		git fetch origin && git checkout --detach $(ESCTEST_COMMIT)

esctest-report:
	ESCTEST_REPORT_LOG=$(CURDIR)/esctest.log swift test --filter testFullSuiteReport
	@grep 'tests passed' esctest.log

run-bench:
	(cd Tools/SwiftTermBenchmarks; swift package benchmark     --target SwiftTermBenchmarks     --benchmark-build-configuration release)
