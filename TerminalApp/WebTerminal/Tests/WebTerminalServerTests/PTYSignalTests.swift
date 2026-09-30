import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import WebTerminalServer

/// Simulates the ignored disposition used by the server's signal source and
/// a worker thread with SIGINT blocked. Never keep this state across await.
private func startWithInheritedInterruptPolicy(_ session: TerminalSession) throws {
    var previousAction = sigaction()
    guard sigaction(SIGINT, nil, &previousAction) == 0 else {
        throw ConfigurationError("Cannot read the test signal disposition.")
    }
    var blocked = sigset_t()
    var previousMask = sigset_t()
    sigemptyset(&blocked)
    sigaddset(&blocked, SIGINT)
    guard pthread_sigmask(SIG_BLOCK, &blocked, &previousMask) == 0 else {
        throw ConfigurationError("Cannot block the test signal.")
    }
    defer {
        _ = sigaction(SIGINT, &previousAction, nil)
        _ = pthread_sigmask(SIG_SETMASK, &previousMask, nil)
    }
    _ = signal(SIGINT, SIG_IGN)
    try session.start(configuration: ServerConfiguration(arguments: ["--shell", "/bin/sh"]))
}

private func waitForPTYText(_ marker: String, session: TerminalSession) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            var text = ""
            while let event = await session.output.next() {
                if case .bytes(let bytes) = event {
                    text += String(decoding: bytes, as: UTF8.self)
                    if text.contains(marker) { return }
                }
            }
            throw ConfigurationError("The PTY closed before it produced \(marker).")
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            session.stop()
            throw ConfigurationError("Timed out waiting for \(marker).")
        }
        defer { group.cancelAll() }
        try await group.next()
    }
}

@Test(.timeLimit(.minutes(1))) func ctrlCStopsCatAfterServerSignalSetup() async throws {
    let session = TerminalSession()
    defer { session.stop() }
    try startWithInheritedInterruptPolicy(session)
    // Repeat through the same interactive shell. The prompt marker proves
    // that foreground cat exited, instead of merely echoing the Ctrl-C byte.
    for _ in 0..<3 {
        try await session.sendInput(Array(
            "stty -echo; PS1=$(printf '\\137CTRL_PROMPT\\137'); printf '\\137CAT_READY\\137\\n'; cat\n".utf8))
        try await waitForPTYText("_CAT_READY_", session: session)
        try await session.sendInput(Array("cat-probe\n".utf8))
        try await waitForPTYText("cat-probe", session: session)
        try await session.sendInput([3])
        try await waitForPTYText("_CTRL_PROMPT_", session: session)
    }
}
