# This is the release toolchain for Swift 5.7.3, but you need the Swift download, the Xcode version lacks the fuzzer
# To get this number, run:
# plutil -extract CFBundleIdentifier raw /Library/Developer/Toolchains/swift-5.7.3-RELEASE.xctoolchain/Info.plist 
TOOLCHAINS=org.swift.573202201171a

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
	xcrun --toolchain $(TOOLCHAINS) swift build -Xswiftc "-sanitize=fuzzer" -Xswiftc "-parse-as-library"

run-fuzzer:
	./.build/debug/SwiftTermFuzz ../SwiftTermFuzzerCorpus -rss_limit_mb=40480 -jobs=12

clone-esctest:
	@if [ -d esctest ]; then \
		echo "esctest directory already exists, updating..."; \
		cd esctest && git fetch && git checkout python3 && git pull; \
	else \
		git clone --branch python3 https://github.com/migueldeicaza/esctest.git esctest; \
	fi

run-bench:
	(cd Tools/SwiftTermBenchmarks; swift package benchmark     --target SwiftTermBenchmarks     --benchmark-build-configuration release)
