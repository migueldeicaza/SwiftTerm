//
// KittyClipboardGrants.swift
//
// Persistent session permissions for OSC 5522 passwords.
//
// A grant is scoped to one password, one direction, one clipboard location,
// and one terminal session. Read and write permissions are separate. RIS and
// terminal destruction clear every grant. One-time authorization is not stored
// here: a paste event issues a paste token instead.
//

/// Session permissions for passwords in the Kitty clipboard protocol.
struct KittyClipboardGrants: Sendable {
    static let maximumCount = 32

    private struct Key: Hashable, Sendable {
        let password: [UInt8]
        let direction: KittyClipboardPermissionDirection
        let location: KittyClipboardLocation
    }

    private var order: [Key] = []
    private var entries: Set<Key> = []

    init() {}

    var count: Int {
        order.count
    }

    /// Remembers one password for one direction and one location.
    mutating func add(
        password: String,
        direction: KittyClipboardPermissionDirection,
        location: KittyClipboardLocation
    ) {
        guard !password.isEmpty else { return }
        let key = Key(password: Array(password.utf8), direction: direction, location: location)
        guard entries.insert(key).inserted else { return }
        if order.count >= Self.maximumCount {
            entries.remove(order.removeFirst())
        }
        order.append(key)
    }

    /// Whether a stored grant covers this password, direction, and location.
    func check(
        password: String,
        direction: KittyClipboardPermissionDirection,
        location: KittyClipboardLocation
    ) -> Bool {
        guard !password.isEmpty else { return false }
        return entries.contains(
            Key(password: Array(password.utf8), direction: direction, location: location))
    }

    mutating func clear() {
        order.removeAll(keepingCapacity: true)
        entries.removeAll(keepingCapacity: true)
    }
}

extension KittyClipboardPermissionDirection: Hashable {}
