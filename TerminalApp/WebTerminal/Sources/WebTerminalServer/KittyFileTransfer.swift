import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Converts session-local Kitty file packets to direct packets. Only the PTY
/// delivery thread changes parser state. Close uses a separate lock so it can
/// cancel a transfer while the output mailbox applies backpressure.
final class KittyFileTransfer: @unchecked Sendable {
    static let maximumFileBytes = 64 * 1024 * 1024
    private static let maximumCommandBytes = 16 * 1024
    let temporaryDirectory: URL
    private let directoryFD: Int32
    private let output: OutputMailbox
    private let parserLock = NSLock()
    private let closeLock = NSLock()
    private var closed = false
    private enum State { case ground, escape, apcStart, kitty, passthrough }
    private var state = State.ground
    private var pending: [UInt8] = []
    private var previousEscape = false
    private var passthroughAllowsBell = false

    init(output: OutputMailbox) throws {
        self.output = output
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftterm-web-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        temporaryDirectory = directory.resolvingSymlinksInPath()
        directoryFD = open(temporaryDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw ConfigurationError("Cannot open the session graphics directory.")
        }
    }

    deinit {
        close()
        _ = systemClose(directoryFD)
    }

    func close() {
        let first = closeLock.withLock {
            guard !closed else { return false }
            closed = true
            return true
        }
        if first { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }

    private var isClosed: Bool { closeLock.withLock { closed } }

    func receive(_ bytes: ArraySlice<UInt8>) {
        parserLock.lock()
        defer { parserLock.unlock() }
        var plain: [UInt8] = []
        plain.reserveCapacity(min(bytes.count, 65536))
        func flushPlain() {
            if !plain.isEmpty { output.send(plain[...]); plain.removeAll(keepingCapacity: true) }
        }
        for byte in bytes {
            if isClosed { return }
            switch state {
            case .ground:
                if byte == 27 {
                    flushPlain()
                    pending = [27]
                    state = .escape
                } else { plain.append(byte) }
            case .escape:
                if byte == 95 {
                    pending.append(byte)
                    state = .apcStart
                } else if byte == 93 || byte == 80 || byte == 94 || byte == 88 {
                    // Do not inspect Kitty-looking bytes inside another string.
                    plain.append(contentsOf: pending)
                    plain.append(byte)
                    pending.removeAll(keepingCapacity: true)
                    previousEscape = false
                    passthroughAllowsBell = byte == 93
                    state = .passthrough
                } else if byte == 27 {
                    plain.append(27)
                } else {
                    plain.append(contentsOf: pending)
                    plain.append(byte)
                    pending.removeAll(keepingCapacity: true)
                    state = .ground
                }
            case .apcStart:
                pending.append(byte)
                if byte == 71 {
                    state = .kitty
                } else {
                    plain.append(contentsOf: pending)
                    pending.removeAll(keepingCapacity: true)
                    previousEscape = byte == 27
                    passthroughAllowsBell = false
                    state = .passthrough
                }
            case .kitty:
                let terminated = pending.last == 27 && byte == 92
                pending.append(byte)
                if terminated {
                    flushPlain()
                    if !convert(pending) { output.send(pending[...]) }
                    pending.removeAll(keepingCapacity: true)
                    state = .ground
                } else if byte == 24 || byte == 26 {
                    plain.append(contentsOf: pending)
                    pending.removeAll(keepingCapacity: true)
                    state = .ground
                } else if pending.count > Self.maximumCommandBytes {
                    plain.append(contentsOf: pending)
                    pending.removeAll(keepingCapacity: true)
                    previousEscape = byte == 27
                    passthroughAllowsBell = false
                    state = .passthrough
                }
            case .passthrough:
                plain.append(byte)
                if (previousEscape && byte == 92) || byte == 24 || byte == 26 || (passthroughAllowsBell && byte == 7) { state = .ground }
                previousEscape = byte == 27
            }
            if plain.count >= 65536 { flushPlain() }
        }
        flushPlain()
    }

    /// A failed local request is forwarded unchanged. The browser terminal
    /// rejects unsupported local media and applies the original q/i/I policy.
    private func convert(_ command: [UInt8]) -> Bool {
        guard command.count >= 6, let separator = command[3..<(command.count - 2)].firstIndex(of: 59),
              let header = String(bytes: command[3..<separator], encoding: .ascii) else { return false }
        let pairs = header.split(separator: ",", omittingEmptySubsequences: false)
        var values: [String: String] = [:]
        for pair in pairs {
            let parts = pair.split(separator: "=", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].utf8.count == 1, !parts[1].isEmpty,
                  values[String(parts[0])] == nil else { return false }
            values[String(parts[0])] = String(parts[1])
        }
        guard let medium = values["t"], medium == "f" || medium == "t",
              values["m"] == nil || values["m"] == "0",
              let pathBytes = Data(base64Encoded: Data(command[(separator + 1)..<(command.count - 2)])),
              pathBytes.count <= 4096, !pathBytes.contains(0),
              let path = String(data: pathBytes, encoding: .utf8),
              let file = openFile(path, temporary: medium == "t") else { return false }
        defer { _ = systemClose(file.fd); _ = systemClose(file.parentFD) }
        guard let offset = unsigned(values["O"], fallback: 0),
              let requested = unsigned(values["S"], fallback: 0),
              offset <= file.size, requested <= file.size - offset else { return false }
        let count = requested == 0 ? file.size - offset : requested
        let retained = pairs.filter { pair in
            guard let key = pair.first else { return false }
            return key != "t" && key != "S" && key != "O" && key != "m"
        }.map(String.init)
        let firstControls = (retained + ["t=d"]).joined(separator: ",")
        let continuationControls = values["q"].map { "q=\($0)" } ?? ""
        var first = true
        var position = offset
        var remaining = count
        // A multiple of three prevents base64 padding between read blocks.
        var raw = [UInt8](repeating: 0, count: min(65535, max(1, count)))
        repeat {
            if isClosed { return true }
            let wanted = min(raw.count, remaining)
            var filled = 0
            while filled < wanted {
                let n = raw.withUnsafeMutableBytes { buffer in
                    pread(file.fd, buffer.baseAddress!.advanced(by: filled), wanted - filled, off_t(position + filled))
                }
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else {
                    if first { return false }
                    // Abort an incomplete direct transfer if the file shrank
                    // or a read failed after earlier chunks were delivered.
                    emit(controls: continuationControls, more: false, payload: [33])
                    return true
                }
                filled += n
            }
            position += filled
            remaining -= filled
            let encoded = Data(raw.prefix(filled)).base64EncodedData()
            var index = 0
            repeat {
                let end = min(index + 4096, encoded.count)
                let more = end < encoded.count || remaining > 0
                emit(controls: first ? firstControls : continuationControls, more: more,
                     payload: Array(encoded[index..<end]))
                first = false
                index = end
                if isClosed { return true }
            } while index < encoded.count
        } while remaining > 0
        if medium == "t" {
            // Delete only the same inode opened through the retained parent
            // directory descriptor. A replacement or symlink is left alone.
            var current = stat()
            if fstatat(file.parentFD, file.name, &current, AT_SYMLINK_NOFOLLOW) == 0,
               current.st_dev == file.device, current.st_ino == file.inode {
                _ = unlinkat(file.parentFD, file.name, 0)
            }
        }
        return true
    }

    private func emit(controls: String, more: Bool, payload: [UInt8]) {
        let separator = controls.isEmpty ? "" : ","
        var packet = Array("\u{1b}_G\(controls)\(separator)m=\(more ? 1 : 0);".utf8)
        packet.append(contentsOf: payload)
        packet.append(contentsOf: [27, 92])
        output.send(packet[...])
    }

    private func unsigned(_ value: String?, fallback: Int) -> Int? {
        guard let value else { return fallback }
        guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let result = Int(value), result <= Self.maximumFileBytes else { return nil }
        return result
    }

    private struct OpenFile {
        let fd: Int32
        let parentFD: Int32
        let name: String
        let size: Int
        let device: dev_t
        let inode: ino_t
    }

    private func openFile(_ path: String, temporary: Bool) -> OpenFile? {
        let prefix = temporaryDirectory.path + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let components = path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              let last = components.last, !temporary || last.hasPrefix("tty-graphics-protocol") else { return nil }
        var parent = dup(directoryFD)
        guard parent >= 0 else { return nil }
        for component in components.dropLast() {
            let next = openat(parent, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            _ = systemClose(parent)
            guard next >= 0 else { return nil }
            parent = next
        }
        let name = String(last)
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { _ = systemClose(parent); return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= Self.maximumFileBytes else {
            _ = systemClose(fd); _ = systemClose(parent)
            return nil
        }
        return OpenFile(fd: fd, parentFD: parent, name: name, size: Int(info.st_size),
                        device: info.st_dev, inode: info.st_ino)
    }
}

private func systemClose(_ fd: Int32) -> Int32 {
#if canImport(Darwin)
    Darwin.close(fd)
#else
    Glibc.close(fd)
#endif
}
