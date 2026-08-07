import Darwin
import Foundation

final class SocketControlServer {
    typealias Handler = (HarnessCommand) throws -> Any

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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.serve(connection)
        }
    }

    private func serve(_ connection: Int32) {
        defer { close(connection) }
        var framer = JSONLineFramer()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(connection, &buffer, buffer.count)
            if count <= 0 { return }
            do {
                let messages = try framer.append(Data(buffer[0..<count]))
                for message in messages {
                    let response = process(message)
                    guard writeResponse(response, to: connection) else { return }
                }
            } catch {
                writeResponse(errorResponse(id: NSNull(), code: "messageTooLarge", message: String(describing: error)), to: connection)
                return
            }
        }
    }

    private func process(_ data: Data) -> [String: Any] {
        var requestID: Any = NSNull()
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw HarnessError.invalidArgument("The request must be a JSON object")
            }
            requestID = object["id"] ?? NSNull()
            guard let commandName = object["command"] as? String, !commandName.isEmpty else {
                throw HarnessError.invalidArgument("The request requires command")
            }
            let rawArguments = object["arguments"] as? [String: Any] ?? [:]
            let commandData = try JSONSerialization.data(withJSONObject: ["command": commandName, "arguments": rawArguments])
            let command = try JSONDecoder().decode(HarnessCommand.self, from: commandData)

            let semaphore = DispatchSemaphore(value: 0)
            var commandResult: Result<Any, Error>!
            DispatchQueue.main.async { [handler] in
                do { commandResult = .success(try handler(command)) }
                catch { commandResult = .failure(error) }
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 600) == .success else {
                throw HarnessError.io("The command timed out after 600 seconds")
            }
            switch commandResult! {
            case .success(let result):
                return ["id": requestID, "ok": true, "result": result]
            case .failure(let error):
                throw error
            }
        } catch let error as HarnessError {
            return errorResponse(id: requestID, code: error.code, message: error.description)
        } catch {
            return errorResponse(id: requestID, code: "invalidRequest", message: error.localizedDescription)
        }
    }

    private func errorResponse(id: Any, code: String, message: String) -> [String: Any] {
        ["id": id, "ok": false, "error": ["code": code, "message": message]]
    }

    @discardableResult
    private func writeResponse(_ response: [String: Any], to connection: Int32) -> Bool {
        guard JSONSerialization.isValidJSONObject(response),
              var data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) else {
            return false
        }
        data.append(0x0a)
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
