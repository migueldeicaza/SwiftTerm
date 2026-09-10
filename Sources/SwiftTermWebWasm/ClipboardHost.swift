import SwiftTerm
#if !SWIFTTERM_EMBEDDED
import Foundation

/// All requests are completed by a later, serialized host call.
final class WasmClipboardState {
    struct Pending {
        let deadline: UInt64
        let complete: (UInt32, [UInt8]) -> Void
    }
    var capabilities: UInt8 = 0
    private var nextID: UInt32 = 1
    private var pending: [UInt32: Pending] = [:]
    static let maximumBytes = 512 * 1024

    func enqueue(host: WasmTerminalHost, operation: UInt32, metadata: [String: Any],
                 completion: @escaping (UInt32, [UInt8]) -> Void) -> Bool {
        expire()
        guard pending.count < 16, nextID < UInt32.max,
              let json = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
              json.count <= ABI.maximumControl - 12 else { return false }
        let id = nextID
        nextID += 1
        var payload: [UInt8] = []
        payload.append32(id); payload.append32(operation); payload.append32(UInt32(json.count))
        payload.append(contentsOf: json)
        guard host.events.append(type: 20, payload: payload) else { host.queueFailure = true; return false }
        pending[id] = Pending(deadline: monotonicMilliseconds() + 30_000, complete: completion)
        return true
    }
    func finish(_ id: UInt32, status: UInt32, bytes: [UInt8]) -> Bool {
        expire()
        guard let item = pending.removeValue(forKey: id) else { return false }
        item.complete(status, bytes)
        return true
    }
    func expire() {
        let now = monotonicMilliseconds()
        let expired = pending.filter { $0.value.deadline <= now }.map { $0.key }
        for id in expired { pending.removeValue(forKey: id)?.complete(1, []) }
    }
    func reset() {
        let previous = pending.values
        pending.removeAll()
        for item in previous { item.complete(1, []) }
    }
}

extension WasmTerminalHost {
    func kittyClipboardCapabilities(source: Terminal) -> KittyClipboardCapabilities {
        KittyClipboardCapabilities(rawValue: clipboard.capabilities)
    }
    func kittyClipboardSendPasteEvent(source: Terminal, data: ArraySlice<UInt8>) -> Bool {
        let accepted = output.append(data)
        if !accepted { queueFailure = true }
        return accepted
    }
    func kittyClipboardAvailableMimeTypes(source: Terminal, location: KittyClipboardLocation,
        completion: @escaping @Sendable ([String]?) -> Void) -> Bool {
        guard location == .standard, clipboard.capabilities & 1 != 0 else { return false }
        return clipboard.enqueue(host: self, operation: 2, metadata: ["location": "standard"]) { status, bytes in
            guard status == 0, let list = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String],
                  list.count <= 16, list.allSatisfy({ $0.utf8.count <= 128 }) else { completion(nil); return }
            completion(list)
        }
    }
    func kittyClipboardRead(source: Terminal, location: KittyClipboardLocation, mimeType: String,
        completion: @escaping @Sendable (KittyClipboardReadResult) -> Void) -> Bool {
        guard location == .standard, clipboard.capabilities & 1 != 0 else { return false }
        return clipboard.enqueue(host: self, operation: 3,
            metadata: ["location": "standard", "mimeTypes": [mimeType]]) { status, bytes in
            switch status {
            case 0: completion(.data(Data(bytes)))
            case 1: completion(.denied)
            case 3: completion(.busy)
            default: completion(.unavailable)
            }
        }
    }
    func kittyClipboardWrite(source: Terminal, location: KittyClipboardLocation, content: KittyClipboardWriteContent,
        completion: @escaping @Sendable (KittyClipboardWriteResult) -> Void) -> Bool {
        guard location == .standard, clipboard.capabilities & 2 != 0 else { return false }
        let representations = content.flattened
        guard representations.count <= 16,
              representations.reduce(0, { $0 + $1.data.count }) <= WasmClipboardState.maximumBytes else {
            completion(.tooLarge); return true
        }
        let records = representations.map { ["mimeType": $0.mimeType, "base64": $0.data.base64EncodedString()] }
        return clipboard.enqueue(host: self, operation: 4,
            metadata: ["location": "standard", "representations": records]) { status, _ in
            let result: KittyClipboardWriteResult
            switch status {
            case 0: result = .success
            case 1: result = .denied
            case 2: result = .unsupported
            case 3: result = .busy
            case 4: result = .invalidData
            case 6: result = .tooLarge
            default: result = .ioError
            }
            completion(result)
        }
    }
    func kittyClipboardRequestPermission(source: Terminal, request: KittyClipboardPermissionRequest,
        completion: @escaping @Sendable (KittyClipboardPermissionResult) -> Void) -> Bool {
        guard request.location == .standard, request.mimeTypes.count <= 16,
              request.mimeTypes.allSatisfy({ $0.utf8.count <= 128 }) else { completion(.deny); return true }
        return clipboard.enqueue(host: self, operation: request.direction == .read ? 0 : 1,
            metadata: ["location": "standard", "name": request.name, "mimeTypes": request.mimeTypes]) { status, _ in
            completion(status == 0 ? .allow(rememberPassword: false) : .deny)
        }
    }
    func clipboardReadRequest(source: Terminal, selection: String) -> Bool {
        // OSC 52 has no unsupported/error response. A denied read sends no data.
        guard clipboard.capabilities & 1 != 0 else { return false }
        return clipboard.enqueue(host: self, operation: 5,
            metadata: ["location": "standard", "mimeTypes": ["text/plain"]]) { [weak source] status, bytes in
            guard status == 0 else { return }
            source?.completeClipboardRead(selection: selection, content: bytes)
        }
    }
}
#else
final class WasmClipboardState {
    func reset() {}
    func expire() {}
}
#endif
