import Foundation
import Testing
@testable import WebTerminalServer

@Test func originMustMatchLoopbackAuthority() {
    #expect(isAllowedWebSocketOrigin(host: "127.0.0.1:8080", origin: "http://127.0.0.1:8080", port: 8080))
    #expect(isAllowedWebSocketOrigin(host: "localhost:8080", origin: "http://localhost:8080", port: 8080))
    #expect(isAllowedWebSocketOrigin(host: "localhost", origin: "http://localhost", port: 80))
    for origin in [nil, "null", "https://localhost:8080", "http://evil.example", "http://localhost:8080.evil.example", "http://localhost:8081", "http://127.0.0.1:8080", "http://localhost:8080/path"] as [String?] {
        #expect(!isAllowedWebSocketOrigin(host: "localhost:8080", origin: origin, port: 8080))
    }
    #expect(!isAllowedWebSocketOrigin(host: "evil.example:8080", origin: "http://evil.example:8080", port: 8080))
    #expect(!isAllowedWebSocketOrigin(host: nil, origin: "http://localhost:8080", port: 8080))
}

@Test func sessionLimitReusesReleasedSlots() async {
    let limit = WebTerminalSessionLimit(maximum: 2)
    #expect(await limit.acquire())
    #expect(await limit.acquire())
    #expect(await !limit.acquire())
    await limit.release()
    #expect(await limit.acquire())
}

@Test func configurationRejectsInvalidValues() throws {
    #expect(throws: ConfigurationError.self) { try ServerConfiguration(arguments: ["--port", "0"]) }
    #expect(throws: ConfigurationError.self) { try ServerConfiguration(arguments: ["--port", "65536"]) }
    #expect(throws: ConfigurationError.self) { try ServerConfiguration(arguments: ["--shell", "sh"]) }
    #expect(throws: ConfigurationError.self) { try ServerConfiguration(arguments: ["--host", "0.0.0.0"]) }
    #expect(throws: ConfigurationError.self) { try ServerConfiguration(arguments: ["--port"]) }
    let configuration = try ServerConfiguration(arguments: ["--port", "9090"], environment: ["SHELL": "missing"])
    #expect(configuration.port == 9090)
    #expect(configuration.shell == "/bin/sh")
    #expect(configuration.assetDirectory.hasSuffix("/Web/dist"))
}

@Test func shellEnvironmentAdvertisesColorWithoutInheritedSuppression() {
    let environment = TerminalSession.shellEnvironment(from: [
        "TERM": "dumb", "COLORTERM": "", "NO_COLOR": "1",
        "COLUMNS": "80", "LINES": "24", "PRESERVED": "yes"
    ])
    #expect(environment["TERM"] == "xterm-256color")
    #expect(environment["COLORTERM"] == "truecolor")
    #expect(environment["NO_COLOR"] == nil)
    #expect(environment["COLUMNS"] == nil)
    #expect(environment["LINES"] == nil)
    #expect(environment["PRESERVED"] == "yes")
}

@Test func resizeBoundsAndPixels() throws {
    let message = ResizeMessage(type: "resize", cols: 96, rows: 31, cellWidth: 9, cellHeight: 20)
    let size = try message.windowSize()
    #expect(size.ws_col == 96 && size.ws_row == 31)
    #expect(size.ws_xpixel == 864 && size.ws_ypixel == 620)
    for (cols, rows) in [(0, 24), (80, 0), (501, 24), (80, 301), (Int.max, 24)] {
        #expect(throws: ConfigurationError.self) {
            try ResizeMessage(type: "resize", cols: cols, rows: rows, cellWidth: nil, cellHeight: nil).windowSize()
        }
    }
    #expect(throws: ConfigurationError.self) {
        try ResizeMessage(type: "command", cols: 80, rows: 24, cellWidth: 9, cellHeight: 20).windowSize()
    }
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(ResizeMessage.self, from: Data(#"{"type":"resize","cols":80.5,"rows":24}"#.utf8))
    }
}

@Test func outputBatcherKeepsSmallInteractiveRepliesImmediate() {
    var batcher = WebSocketOutputBatcher()
    for index in 0..<1_000 {
        let shouldBatch = batcher.shouldBatch(byteCount: 9, at: UInt64(index) * 500_000)
        #expect(!shouldBatch)
    }
}

@Test func outputBatcherActivatesForSustainedBulkOutput() throws {
    var batcher = WebSocketOutputBatcher()
    var activationTime: UInt64?
    for index in 0..<1_000 {
        let now = UInt64(index) * 50_000
        if batcher.shouldBatch(byteCount: 128, at: now) {
            activationTime = now
            break
        }
    }
    let activated = try #require(activationTime)
    let remainsActive = batcher.shouldBatch(byteCount: 1, at: activated + 49_000_000)
    let expiresAfterIdle = batcher.shouldBatch(byteCount: 1, at: activated + 100_000_000)
    #expect(remainsActive)
    #expect(!expiresAfterIdle)
}

@Test func outputBatcherStopsAfterBulkChangesToSmallReplies() {
    var batcher = WebSocketOutputBatcher()
    let activated = batcher.shouldBatch(byteCount: 32 * 1024, at: 0)
    #expect(activated)
    for milliseconds in 1..<100 {
        let shouldBatch = batcher.shouldBatch(byteCount: 9, at: UInt64(milliseconds) * 1_000_000)
        #expect(shouldBatch == (milliseconds < 50))
    }
}

@Test func outputBatcherDetectsNewBulkDuringTheActiveWindow() {
    var batcher = WebSocketOutputBatcher()
    let activated = batcher.shouldBatch(byteCount: 32 * 1024, at: 0)
    #expect(activated)
    let firstHalf = batcher.shouldBatch(byteCount: 16 * 1024, at: 10_000_000)
    let secondHalf = batcher.shouldBatch(byteCount: 16 * 1024, at: 20_000_000)
    #expect(firstHalf && secondHalf)
    // The new burst extends the window to 70 ms. Small output does not renew it.
    let beforeDeadline = batcher.shouldBatch(byteCount: 9, at: 69_000_000)
    let atDeadline = batcher.shouldBatch(byteCount: 9, at: 70_000_000)
    #expect(beforeDeadline)
    #expect(!atDeadline)
}

@Test func mailboxPreservesBytesAndExitOrder() async {
    let mailbox = OutputMailbox(capacity: 3)
    Thread.detachNewThread {
        mailbox.send([1, 2, 3, 4, 5, 6, 7][...])
        mailbox.finish(exitCode: 7)
    }
    #expect(await mailbox.next() == .bytes([1, 2, 3]))
    #expect(await mailbox.next() == .bytes([4, 5, 6]))
    #expect(await mailbox.next() == .bytes([7]))
    #expect(await mailbox.next() == .exit(7))
    #expect(await mailbox.next() == nil)
}

@Test func mailboxCombinesQueuedChunks() async {
    let mailbox = OutputMailbox(capacity: 6)
    mailbox.send([1, 2][...])
    mailbox.send([3, 4][...])
    mailbox.send([5, 6][...])
    #expect(await mailbox.next() == .bytes([1, 2, 3, 4, 5, 6]))
    mailbox.close()
}

@Test func mailboxAppendsBytesThatArriveAfterFirstRead() async {
    let mailbox = OutputMailbox(capacity: 6)
    let reader = Task { await mailbox.next() }
    mailbox.send([1, 2][...])
    guard case .bytes(var bytes) = await reader.value else {
        Issue.record("The first output event must contain bytes.")
        return
    }
    mailbox.send([3, 4][...])
    mailbox.send([5, 6][...])
    mailbox.appendAvailableBytes(to: &bytes)
    #expect(bytes == [1, 2, 3, 4, 5, 6])
    mailbox.finish(exitCode: 7)
    #expect(await mailbox.next() == .exit(7))
}

@Test func mailboxCancellationWakesConsumerAndProducer() async {
    let mailbox = OutputMailbox(capacity: 1)
    let reader = Task { await mailbox.next() }
    reader.cancel()
    #expect(await reader.value == nil)
    await withCheckedContinuation { continuation in
        Thread.detachNewThread {
            mailbox.send([1, 2][...])
            continuation.resume()
        }
    }
    #expect(await mailbox.next() == nil)
}

@Test(.timeLimit(.minutes(1))) func shellReceivesInputResizeAndReportsExit() async throws {
    let configuration = try ServerConfiguration(arguments: ["--shell", "/bin/sh"])
    let session = TerminalSession()
    defer { session.stop() }
    try session.start(configuration: configuration)
    try session.resize(.init(type: "resize", cols: 96, rows: 31, cellWidth: 9, cellHeight: 20))
    // Octal escapes make the result distinct from the PTY's input echo.
    try await session.sendInput(Array("stty -echo; printf '\\137SWIFTTERM\\137'; stty size; exit 7\n".utf8))
    let result = try await withThrowingTaskGroup(of: String.self) { group in
        group.addTask {
            var text = ""
            while let event = await session.output.next() {
                switch event {
                case .bytes(let bytes): text += String(decoding: bytes, as: UTF8.self)
                case .exit(let code):
                    #expect(code == 7)
                    return text
                }
            }
            throw ConfigurationError("The PTY closed without an exit event.")
        }
        group.addTask {
            try await Task.sleep(for: .seconds(10))
            session.stop()
            throw ConfigurationError("The PTY test timed out.")
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
    #expect(result.contains("_SWIFTTERM_31 96"))
}

@Test(.timeLimit(.minutes(1))) func inputTimeoutClosesBlockedPTYSession() async throws {
    let session = TerminalSession()
    defer { session.stop() }
    try session.start(configuration: ServerConfiguration(arguments: ["--shell", "/bin/sh"]))
    // Use a builtin loop so no descendant can keep the PTY open after cleanup.
    // Escape the marker so the input echo cannot satisfy the readiness check.
    try await session.sendInput(Array(
        "stty raw -echo; printf '\\137SWIFTTERM\\137BLOCKED\\137'; while :; do :; done\n".utf8))
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            var text = ""
            while let event = await session.output.next() {
                if case .bytes(let bytes) = event {
                    text += String(decoding: bytes, as: UTF8.self)
                    if text.contains("_SWIFTTERM_BLOCKED_") { return }
                }
            }
            throw ConfigurationError("The shell closed before it stopped reading input.")
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            session.stop()
            throw ConfigurationError("The shell did not report readiness.")
        }
        defer { group.cancelAll() }
        try await group.next()
    }

    // This is larger than the PTY input buffer. The shell does not read it.
    // A separate deadline prevents a failed timeout implementation from
    // leaving the test or child alive indefinitely.
    let start = ContinuousClock.now
    let timedOut = try await withThrowingTaskGroup(of: Bool.self) { group in
        group.addTask {
            do {
                try await session.sendInput(Array(repeating: UInt8(65), count: 1024 * 1024), timeout: .milliseconds(100))
                return false
            } catch {
                return true
            }
        }
        group.addTask {
            try await Task.sleep(for: .seconds(3))
            session.stop()
            return false
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
    #expect(timedOut, "The short PTY write timeout must complete before the test deadline.")
    #expect(start.duration(to: .now) < .seconds(2))
    #expect(await session.output.next() == nil)
    #expect(throws: ConfigurationError.self) {
        try session.resize(.init(type: "resize", cols: 80, rows: 24, cellWidth: nil, cellHeight: nil))
    }
}
