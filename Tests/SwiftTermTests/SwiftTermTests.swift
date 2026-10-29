#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import SwiftTerm

/// Runs esctest (https://github.com/ThomasDickey/esctest2) against SwiftTerm.
///
/// `make clone-esctest` fetches the pinned esctest commit into `esctest/`.
/// Without it, the esctest tests skip themselves.
///
/// esctest only knows how to check a terminal that answers like a real one,
/// so it runs with xterm's expectations: an 80x25 screen that follows the
/// resize requests esctest sends before each test, and xterm patch 411 for
/// DECRQCRA checksums and reverse wraparound.
final class SwiftTermTests {
    static let projectRoot: URL = {
        // Compute path relative to source file to work from any working directory (including Xcode)
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }()
    static let esctest: String = projectRoot.appendingPathComponent("esctest/esctest/esctest.py").path
    static let queue: DispatchQueue = {
        let queue = DispatchQueue(label: "Runner", qos: .userInteractive, attributes: .concurrent, autoreleaseFrequency: .inherit, target: nil)
        return queue
    }()
    static let esctestArguments = [
        "--expected-terminal=xterm",
        "--xterm-checksum=411",
        "--xterm-reverse-wrap=411",
        "--timeout=0.2",
    ]
    // Tests run in parallel, so each one needs its own esctest log.
    let logfile = NSTemporaryDirectory() + "log-\(UUID().uuidString)"

    /// The terminal that esctest runs in. Unlike `HeadlessTerminal`, it
    /// follows XTWINOPS resize requests and tells the pty about each new size.
    final class EsctestHost: TerminalDelegate, LocalProcessDelegate {
        var terminal: Terminal!
        var process: LocalProcess!
        let exited = DispatchSemaphore(value: 0)

        init() {
            var options = TerminalOptions.default
            options.cols = 80
            options.rows = 25
            terminal = Terminal(delegate: self, options: options)
            // A serial queue, so that two reads never feed the terminal at once.
            process = LocalProcess(delegate: self, dispatchQueue: DispatchQueue(label: "esctest"))
        }

        func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
            exited.signal()
        }

        func dataReceived(slice: ArraySlice<UInt8>) {
            terminal.feed(buffer: slice)
        }

        func getWindowSize() -> winsize {
            winsize(ws_row: UInt16(terminal.rows), ws_col: UInt16(terminal.cols),
                    ws_xpixel: UInt16(terminal.cols * 10), ws_ypixel: UInt16(terminal.rows * 20))
        }

        func send(source: Terminal, data: ArraySlice<UInt8>) {
            process.send(data: data)
        }

        func sizeChanged(source: Terminal) {
            var size = getWindowSize()
            _ = ioctl(process.childfd, TIOCSWINSZ, &size)
        }

        func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? {
            if case .resizeTerminal(let cols, let rows) = command {
                // As xterm, keep a dimension that is given as zero.
                terminal.resize(cols: cols == 0 ? terminal.cols : cols,
                                rows: rows == 0 ? terminal.rows : rows)
                sizeChanged(source: terminal)
            }
            return nil
        }
    }

    func pythonBin() -> String? {
        // Check environment variable first
        if let pythonEnv = getenv("PYTHON_BIN") {
            return String(validatingCString: pythonEnv)
        }

        // Check common Python 3 locations
        let candidates = [
            "/usr/bin/python3",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3"
        ]

        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    /// Runs the esctest tests whose `Class.test_name` matches `includeRegexp`,
    /// and returns esctest's log, or nil when esctest or Python is missing.
    func runEsctest(_ includeRegexp: String) -> String? {
        if !FileManager.default.fileExists(atPath: SwiftTermTests.esctest) {
            print("Skipping test - esctest not found at \(SwiftTermTests.esctest), run make clone-esctest")
            return nil
        }
        guard let python = pythonBin() else {
            print("Skipping test - Python 3 executable not found")
            return nil
        }
        try? FileManager.default.removeItem(atPath: logfile)

        let host = EsctestHost()
        let args = [SwiftTermTests.esctest] + SwiftTermTests.esctestArguments +
            ["--logfile=\(logfile)", "--include=\(includeRegexp)"]
        let directory = (SwiftTermTests.esctest as NSString).deletingLastPathComponent
        host.process.startProcess(executable: python, args: args, environment: nil,
                                  currentDirectory: directory)
        withExtendedLifetime(host) {
            host.exited.wait()
        }
        do {
            return try String(contentsOf: URL(fileURLWithPath: logfile), encoding: .isoLatin1)
        } catch {
            return "Exception while loading \(logfile) \(error)"
        }
    }

    /// Returns nil when every matching test passes or esctest is missing,
    /// otherwise esctest's log.
    func runTester(_ includeRegexp: String) -> String? {
        guard let log = runEsctest(includeRegexp) else {
            return nil
        }
        if log.contains(" 0 tests failed ***") {
            return nil
        }
        return log
    }

    /// The `Class.test_name` of each test in Fixtures/esctest-known-good.txt.
    static func knownGoodTests() throws -> [String] {
        let url = try #require(Bundle.module.url(forResource: "esctest-known-good", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Fails if a test on the allowlist fails. The names are anchored, so
    /// `BS` does not also select `BS_ReverseWrap...`.
    @Test func testKnownGood() throws {
        let names = try SwiftTermTests.knownGoodTests()
        #expect(!names.isEmpty)
        let alternatives = names.map { NSRegularExpression.escapedPattern(for: $0) }
        #expect(runTester("^(\(alternatives.joined(separator: "|")))$") == nil)
    }

    /// Runs the whole suite and writes esctest's log to the path in
    /// ESCTEST_REPORT_LOG. It reports and never fails because of esctest
    /// failures; scripts/esctest-known-good.py makes the allowlist from it.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ESCTEST_REPORT_LOG"] != nil))
    func testFullSuiteReport() throws {
        let path = try #require(ProcessInfo.processInfo.environment["ESCTEST_REPORT_LOG"])
        guard let log = runEsctest(".") else {
            Issue.record("esctest is not available, run make clone-esctest")
            return
        }
        try log.write(toFile: path, atomically: true, encoding: .isoLatin1)
        let summary = log.split(separator: "\n").first { $0.contains(" tests passed") }
        print(summary.map(String.init) ?? "esctest wrote no summary")
    }

    // Use this test to run a single test
    @Test func testSingle() {
        #expect(runTester("test_ChangeColor_Hash3$") == nil)
    }
    
    @Test func testWraparound() {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!
        
        // Sends a long line
        var long = "A"
        for _ in 0..<79 {
            long.append("a")
        }
        long.append("B")
        t.feed (text: long)
        #expect(t.getCharacter (col:0, row: 0) == "A")
        #expect(t.getCharacter (col:1, row: 0) == "a")
        #expect(t.getCharacter (col:0, row: 1) == "B")
    }
}
#endif
