all:
	echo nothing defined by default

jazzy:
	jazzy --clean --author "Miguel de Icaza" --author_url https://tirania.org/ --github_url https://github.com/migueldeicaza/SwiftTerm --github-file-prefix https://github.com/migueldeicaza/SwiftTerm/tree/master --module-version 1.0 --module SwiftTerm --root-url https://migueldeicaza.github.io/SwiftTerm/ --output docs --build-tool-arguments -scheme,MacTerminal

build-fuzzer:
	(cd SwiftTerm; SWIFT_EXEC=/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin/swiftc  swift build -Xswiftc "-sanitize=fuzzer" -Xswiftc "-parse-as-library")

run-fuzzer:
	SwiftTerm/.build/debug/SwiftTermFuzz ../SwiftTermFuzzerCorpus -rss_limit_mb=40480 -jobs=12
