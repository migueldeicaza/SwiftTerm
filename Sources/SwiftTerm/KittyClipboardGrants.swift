enum KittyClipboardGrantDirection: Sendable {
    case read
    case write
}

enum KittyClipboardGrantLifetime: Sendable {
    case oneTime
    case persistent
}

/// Session permissions for passwords in the Kitty clipboard protocol.
struct KittyClipboardGrants: Sendable {
    static let maximumCount = 32

    private struct Entry: Sendable {
        let password: [UInt8]
        var permitsRead = false
        var permitsWrite = false
        var lifetime: KittyClipboardGrantLifetime
    }

    private var entries: [Entry] = []

    init() {}

    var count: Int {
        entries.count
    }

    /// Adds a direction to a password grant. Existing persistent grants stay persistent.
    mutating func add(
        password: String,
        direction: KittyClipboardGrantDirection,
        lifetime: KittyClipboardGrantLifetime
    ) {
        guard !password.isEmpty else {
            return
        }
        let passwordBytes = Array(password.utf8)

        if let index = entries.firstIndex(where: { $0.password == passwordBytes }) {
            Self.merge(direction: direction, lifetime: lifetime, into: &entries[index])
            return
        }

        if entries.count >= Self.maximumCount {
            entries.removeFirst()
        }

        var entry = Entry(password: passwordBytes, lifetime: lifetime)
        Self.merge(direction: direction, lifetime: lifetime, into: &entry)
        entries.append(entry)
    }

    /// Checks a grant. The check consumes a one-time grant before direction matching.
    mutating func check(
        password: String,
        direction: KittyClipboardGrantDirection
    ) -> Bool {
        guard !password.isEmpty else {
            return false
        }
        let passwordBytes = Array(password.utf8)
        guard let index = entries.firstIndex(where: { $0.password == passwordBytes }) else {
            return false
        }

        let entry = entries[index]
        if entry.lifetime == .oneTime {
            entries.remove(at: index)
        }

        switch direction {
        case .read:
            return entry.permitsRead
        case .write:
            return entry.permitsWrite
        }
    }

    mutating func revoke(password: String) {
        let passwordBytes = Array(password.utf8)
        entries.removeAll { $0.password == passwordBytes }
    }

    mutating func clear() {
        entries.removeAll(keepingCapacity: true)
    }

    private static func merge(
        direction: KittyClipboardGrantDirection,
        lifetime: KittyClipboardGrantLifetime,
        into entry: inout Entry
    ) {
        switch direction {
        case .read:
            entry.permitsRead = true
        case .write:
            entry.permitsWrite = true
        }

        if lifetime == .persistent {
            entry.lifetime = .persistent
        }
    }
}
