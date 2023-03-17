# This is the release toolchain for Swift 5.7.3, but you need the Swift download, the Xcode version lacks the fuzzer
# To get this number, run:
# plutil -extract CFBundleIdentifier raw /Library/Developer/Toolchains/swift-5.7.3-RELEASE.xctoolchain/Info.plist 
TOOLCHAINS=org.swift.573202201171a

all:
	echo nothing defined by default

jazzy:
	(cd TerminalApp; DYLD_FALLBACK_LIBRARY_PATH=/Users/miguel/opt/anaconda3/lib/ jazzy --clean --author "Miguel de Icaza" --author_url https://tirania.org/ --github_url https://github.com/migueldeicaza/SwiftTerm --github-file-prefix https://github.com/migueldeicaza/SwiftTerm/tree/master --module-version 1.0 --module SwiftTerm --root-url https://migueldeicaza.github.io/SwiftTerm/ --output ../docs --build-tool-arguments -scheme,MacTerminal,-project,MacTerminal.xcodeproj)

build-fuzzer:
	xcrun --toolchain $(TOOLCHAINS) swift build -Xswiftc "-sanitize=fuzzer" -Xswiftc "-parse-as-library"

run-fuzzer:
	./.build/debug/SwiftTermFuzz ../SwiftTermFuzzerCorpus -rss_limit_mb=40480 -jobs=12
