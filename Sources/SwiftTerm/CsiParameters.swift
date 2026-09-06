//
//  CsiParameters.swift
//  SwiftTerm
//

/// Accumulates the parameters of one CSI or DCS sequence without heap
/// storage. The parser owns one instance and moves it into a local during
/// `parse`, so reentrant parsing keeps the current sequence intact.
///
/// Every mutation goes through an in-place pointer to the tuple. Nothing
/// here reads the tuple by value: a nonmutating accessor that takes a
/// pointer to it (or a `switch` over its elements) makes the compiler copy or
/// jump-table 24 words, which was measurable on dense SGR input. Handlers
/// receive a ``CsiParameters`` view from ``withView(_:)`` instead.
struct CsiParameterStorage {
    static let capacity = EscapeSequenceParser.maximumParameterCount

    private var storage: (
        Int, Int, Int, Int, Int, Int,
        Int, Int, Int, Int, Int, Int,
        Int, Int, Int, Int, Int, Int,
        Int, Int, Int, Int, Int, Int
    )

    private(set) var count: Int

    @inline(__always)
    init() {
        storage = (
            0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0
        )
        count = 0
    }

    @inline(__always)
    private mutating func withElements<R>(_ body: (UnsafeMutablePointer<Int>) -> R) -> R {
        withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: Int.self, capacity: Self.capacity, body)
        }
    }

    @inline(__always)
    mutating func append(_ value: Int) {
        precondition(count < Self.capacity)
        let index = count
        withElements { $0[index] = value }
        count = index + 1
    }

    /// Restores the parser's initial parameter state: exactly one zero.
    @inline(__always)
    mutating func reset() {
        count = 1
        withElements { $0[0] = 0 }
    }

    /// Appends one decimal digit to the last parameter with the parser's
    /// overflow clamp.
    @inline(__always)
    mutating func accumulateDigit(_ code: UInt8) {
        precondition(count > 0)
        let index = count - 1
        withElements { elements in
            elements[index] = EscapeSequenceParser.appendingParameterDigit(code, to: elements[index])
        }
    }

    /// Runs `body` with a read-only view of the active parameters. The view
    /// is only valid inside `body`; handlers must copy what they keep.
    @inline(__always)
    mutating func withView<R>(_ body: (CsiParameters) throws -> R) rethrows -> R {
        let count = self.count
        return try withUnsafeMutablePointer(to: &storage) { pointer in
            try pointer.withMemoryRebound(to: Int.self, capacity: Self.capacity) { elements in
                try body(CsiParameters(base: UnsafePointer(elements), count: count))
            }
        }
    }
}

/// A read-only view of one sequence's parameters, valid for the duration of
/// the dispatch call that received it. Reading an element is a single load.
struct CsiParameters: RandomAccessCollection {
    typealias Index = Int
    typealias Element = Int

    private let base: UnsafePointer<Int>
    let count: Int

    @inline(__always)
    init(base: UnsafePointer<Int>, count: Int) {
        self.base = base
        self.count = count
    }

    /// A view with no parameters, for handlers that ESC sequences and mode
    /// switches invoke without a CSI. The base is never dereferenced.
    nonisolated(unsafe) static let empty = CsiParameters(base: emptyBase, count: 0)
    nonisolated(unsafe) private static let emptyBase: UnsafePointer<Int> = {
        let base = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        base.initialize(to: 0)
        return UnsafePointer(base)
    }()

    var startIndex: Int { 0 }
    var endIndex: Int { count }
    var isEmpty: Bool { count == 0 }

    @inline(__always)
    subscript(index: Int) -> Int {
        precondition(index >= 0 && index < count)
        return base[index]
    }

    static func == (lhs: CsiParameters, rhs: [Int]) -> Bool {
        lhs.count == rhs.count && lhs.elementsEqual(rhs)
    }

    /// Lets handlers keep `switch pars { case [1, 2]: ... }` patterns.
    static func ~= (pattern: [Int], value: CsiParameters) -> Bool {
        value == pattern
    }
}
