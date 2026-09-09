import Darwin
import Foundation

final class SocketControlServer {
    typealias Handler = @MainActor @Sendable (HarnessCommand) throws -> Any

    private struct ControlRequest: Decodable, Sendable {
        var id: JSONValue?
        var command: String
        var arguments: [String: JSONValue] = [:]
    }

    private let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "org.swiftterm.BidiHarness.socket", qos: .userInitiated)
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?

    init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw HarnessError.invalidArgument("The Unix socket path is too long")
        }
        guard listener == -1 else { return }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posixError("socket") }
        listener = descriptor

        unlink(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: pathBytes)
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, length)
            }
        }
        guard bindResult == 0 else {
            let error = posixError("bind")
            stop()
            throw error
        }
        guard chmod(path, S_IRUSR | S_IWUSR) == 0 else {
            let error = posixError("chmod")
            stop()
            throw error
        }
        guard Darwin.listen(descriptor, 8) == 0 else {
            let error = posixError("listen")
            stop()
            throw error
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    func stop() {
        if let source {
            source.cancel()
            self.source = nil
        } else if listener >= 0 {
            close(listener)
        }
        listener = -1
        unlink(path)
    }

    deinit {
        stop()
    }

    private func acceptConnection() {
        let connection = Darwin.accept(listener, nil, nil)
        guard connection >= 0 else { return }
        let handler = handler
        DispatchQueue.global(qos: .userInitiated).async {
            Self.serve(connection, handler: handler)
        }
    }

    private static func serve(_ connection: Int32, handler: Handler) {
        defer { close(connection) }
        var framer = JSONLineFramer()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(connection, &buffer, buffer.count)
            if count <= 0 { return }
            do {
                let messages = try framer.append(Data(buffer[0..<count]))
                for message in messages {
                    guard let response = process(message, handler: handler),
                          writeResponse(response, to: connection) else { return }
                }
            } catch {
                if let response = Self.encodedErrorResponse(
                    id: .null,
                    code: "messageTooLarge",
                    message: String(describing: error)) {
                    writeResponse(response, to: connection)
                }
                return
            }
        }
    }

    private static func process(_ data: Data, handler: Handler) -> Data? {
        var requestID = JSONValue.null
        do {
            let request = try JSONDecoder().decode(ControlRequest.self, from: data)
            requestID = request.id ?? .null
            guard !request.command.isEmpty else {
                throw HarnessError.invalidArgument("The request requires command")
            }
            let command = HarnessCommand(
                command: request.command,
                arguments: request.arguments)
            let responseID = requestID

            return DispatchQueue.main.sync {
                do {
                    return Self.encodedResponse([
                        "id": responseID.foundationValue,
                        "ok": true,
                        "result": try handler(command),
                    ])
                } catch let error as HarnessError {
                    return Self.encodedErrorResponse(
                        id: responseID,
                        code: error.code,
                        message: error.description)
                } catch {
                    return Self.encodedErrorResponse(
                        id: responseID,
                        code: "invalidRequest",
                        message: error.localizedDescription)
                }
            }
        } catch let error as HarnessError {
            return Self.encodedErrorResponse(
                id: requestID,
                code: error.code,
                message: error.description)
        } catch {
            return Self.encodedErrorResponse(
                id: requestID,
                code: "invalidRequest",
                message: error.localizedDescription)
        }
    }

    private static func encodedErrorResponse(
        id: JSONValue,
        code: String,
        message: String
    ) -> Data? {
        Self.encodedResponse([
            "id": id.foundationValue,
            "ok": false,
            "error": ["code": code, "message": message],
        ])
    }

    private static func encodedResponse(_ response: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(response),
              var data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) else {
            return nil
        }
        data.append(0x0a)
        return data
    }

    @discardableResult
    private static func writeResponse(_ data: Data, to connection: Int32) -> Bool {
        return data.withUnsafeBytes { bytes in
            guard var pointer = bytes.baseAddress else { return false }
            var remaining = bytes.count
            while remaining > 0 {
                let written = Darwin.write(connection, pointer, remaining)
                if written <= 0 { return false }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
            return true
        }
    }

    private func posixError(_ operation: String) -> HarnessError {
        HarnessError.io("\(operation) failed: \(String(cString: strerror(errno)))")
    }
}
