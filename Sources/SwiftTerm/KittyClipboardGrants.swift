import Foundation

enum KittyClipboardGrantDirection: Sendable, Equatable {
    case read
    case write
}

/// Session grants for Kitty clipboard passwords.
struct KittyClipboardGrants: Sendable {
    static let maximumCount = 32

    private struct Entry: Sendable {
        let password: Data
        let direction: KittyClipboardGrantDirection
        let location: KittyClipboardLocation
        let order: UInt64
    }

    private var entries: [Entry] = []

    var count: Int { entries.count }
    var oldestOrder: UInt64? { entries.first?.order }

    mutating func remove(
        password: Data,
        direction: KittyClipboardGrantDirection,
        location: KittyClipboardLocation
    ) {
        entries.removeAll {
            $0.password == password && $0.direction == direction && $0.location == location
        }
    }

    mutating func removeOldest() {
        if !entries.isEmpty { entries.removeFirst() }
    }

    mutating func add(
        password: Data,
        direction: KittyClipboardGrantDirection,
        location: KittyClipboardLocation,
        order: UInt64
    ) {
        guard !password.isEmpty else { return }
        remove(password: password, direction: direction, location: location)
        entries.append(Entry(
            password: password,
            direction: direction,
            location: location,
            order: order))
    }

    func contains(
        password: Data?,
        direction: KittyClipboardGrantDirection,
        location: KittyClipboardLocation
    ) -> Bool {
        guard let password, !password.isEmpty else { return false }
        return entries.contains {
            $0.password == password && $0.direction == direction && $0.location == location
        }
    }

    mutating func clear() {
        entries.removeAll(keepingCapacity: true)
    }
}
