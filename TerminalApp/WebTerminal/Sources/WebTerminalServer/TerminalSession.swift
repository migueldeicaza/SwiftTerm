import Foundation
import WSCore
import NIOCore
import SwiftTerm
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct ResizeMessage: Decodable, Sendable {
    let type: String
    let cols: Int
    let rows: Int
    let cellWidth: Int?
    let cellHeight: Int?

    func windowSize() throws -> winsize {
        guard type == "resize", (2...500).contains(cols), (2...300).contains(rows),
            (0...200).contains(cellWidth ?? 0), (0...200).contains(cellHeight ?? 0)
        else { throw ConfigurationError("Invalid terminal size.") }
        return winsize(
            ws_row: UInt16(rows), ws_col: UInt16(cols),
            ws_xpixel: UInt16(clamping: cols * (cellWidth ?? 0)),
            ws_ypixel: UInt16(clamping: rows * (cellHeight ?? 0))
        )
    }
}

/// The lock protects the process reference and window size. LocalProcess guards
/// its own file descriptor and PID. No process reference is kept across await.
final class TerminalSession: LocalProcessDelegate, @unchecked Sendable {
    let output = OutputMailbox()
    private let lock = NSLock()
    private var process: LocalProcess?
    private var kittyTransfer: KittyFileTransfer?
    private var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)

    func start(configuration: ServerConfiguration) throws {
        let transfer = try KittyFileTransfer(output: output)
        let child = LocalProcess(delegate: self, directDelivery: true)
        // Allow final output to drain through a slow connection before exit.
        child.drainTimeout = 15
        lock.withLock { process = child; kittyTransfer = transfer }
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TMPDIR"] = transfer.temporaryDirectory.path
        environment.removeValue(forKey: "COLUMNS")
        environment.removeValue(forKey: "LINES")
        do {
            try child.startProcessChecked(
                executable: configuration.shell, args: ["-i"],
                environment: environment.map { "\($0.key)=\($0.value)" },
                currentDirectory: configuration.directory
            ).get()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        // Wake a blocked output callback before releasing the process. Its
        // deinitializer closes input, terminates the child, and reaps it.
        output.close()
        let resources = lock.withLock {
            let resources = (process, kittyTransfer)
            process = nil
            kittyTransfer = nil
            return resources
        }
        resources.1?.close()
        resources.0?.terminate()
    }

    func sendInput(_ bytes: [UInt8], timeout: Duration = .seconds(10)) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.writeInput(bytes) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    // A close frame cannot be read while input waits for the PTY.
                    // Bound that wait even if the child no longer reads stdin.
                    self.stop()
                    throw ConfigurationError("The shell did not accept input within ten seconds.")
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        } onCancel: {
            self.stop()
        }
    }

    private func writeInput(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.withLock {
                guard let child = process else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                child.send(data: bytes[...]) { result in
                    continuation.resume(with: result.map { _ in () }.mapError { $0 as any Error })
                }
            }
        }
    }

    func resize(_ message: ResizeMessage) throws {
        var newSize = try message.windowSize()
        let updated = lock.withLock {
            size = newSize
            return process?.updateWindowSize(&newSize) ?? false
        }
        guard updated else { throw ConfigurationError("Cannot resize the terminal.") }
    }

    func getWindowSize() -> winsize { lock.withLock { size } }
    func dataReceived(slice: ArraySlice<UInt8>) {
        let transfer = lock.withLock { kittyTransfer }
        transfer?.receive(slice)
    }
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) { output.finish(exitCode: exitCode) }

    static func run(
        incoming: WebSocketInboundStream,
        outgoing: WebSocketOutboundWriter,
        configuration: ServerConfiguration
    ) async {
        let session = TerminalSession()
        defer { session.stop() }
        do {
            try session.start(configuration: configuration)
            try await outgoing.write(.text("{\"type\":\"ready\"}"))
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for try await message in incoming.messages(maxSize: 64 * 1024) {
                            try Task.checkCancellation()
                            switch message {
                            case .binary(let buffer):
                                guard buffer.readableBytes <= 64 * 1024 else {
                                    throw ConfigurationError("Terminal input is too large.")
                                }
                                try await session.sendInput(Array(buffer.readableBytesView))
                            case .text(let text):
                                guard text.utf8.count <= 1024 else {
                                    throw ConfigurationError("Terminal control message is too large.")
                                }
                                let resize = try JSONDecoder().decode(ResizeMessage.self, from: Data(text.utf8))
                                try session.resize(resize)
                            }
                        }
                    }
                    group.addTask {
                        while let event = await session.output.next() {
                            try Task.checkCancellation()
                            switch event {
                            case .bytes(let bytes):
                                try await outgoing.writeBinaryMessage(ByteBuffer(bytes: bytes))
                            case .exit(let code):
                                try await outgoing.write(.text("{\"type\":\"exit\",\"code\":\(code.map(String.init) ?? "null")}"))
                                return
                            }
                        }
                    }
                    // Closing the process also completes any blocked input write.
                    defer { session.stop(); group.cancelAll() }
                    try await group.next()
                }
            } onCancel: {
                session.stop()
            }
        } catch {
            if !Task.isCancelled {
                let control = ["type": "error", "message": "The terminal session ended: \(error)"]
                if let data = try? JSONEncoder().encode(control), let text = String(data: data, encoding: .utf8) {
                    try? await outgoing.write(.text(text))
                }
            }
        }
    }
}
