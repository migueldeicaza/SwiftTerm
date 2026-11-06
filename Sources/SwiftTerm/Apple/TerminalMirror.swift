//
//  TerminalMirror.swift
//  SwiftTerm
//
//  Mirrors a terminal view to another terminal: a snapshot of its state,
//  then every batch it parses, in order.
//

#if !SWIFTTERM_EMBEDDED
#if os(macOS) || os(iOS) || os(visionOS) || os(macCatalyst)
import Foundation

/// What a mirror of a terminal view hears, in order.
public enum TerminalMirrorUpdate: Sendable {
    /// Bytes that make a terminal of `columns` × `rows` show what this one
    /// shows (see ``Terminal/mirrorSnapshot(scrollback:)``). Always first.
    case snapshot([UInt8], columns: Int, rows: Int)
    /// One batch the terminal parsed after the snapshot, as it arrived.
    case output(ArraySlice<UInt8>)
    /// The terminal changed size after the snapshot, or the view laid it out
    /// again, which resets some modes. The bytes don't carry either, so a
    /// mirror fed only the bytes stops matching: take a fresh snapshot.
    case resized(columns: Int, rows: Int)
}

/// A running mirror. Nothing more is delivered once ``cancel()`` returns,
/// and releasing it cancels it too.
public final class TerminalMirrorSubscription: Sendable {
    private let cancellation: Locked<(@Sendable () -> Void)?>

    init(cancellation: (@Sendable () -> Void)?) {
        self.cancellation = Locked(cancellation)
    }

    /// Stops the mirror. When a feed is being parsed on another thread, this
    /// waits for it to finish. It may be called from the mirror's handler.
    public func cancel() {
        let action = cancellation.withLock { action in
            defer { action = nil }
            return action
        }
        action?()
    }

    deinit {
        cancel()
    }
}

extension TerminalView {
    /// Starts mirroring this terminal.
    ///
    /// `handler` hears ``TerminalMirrorUpdate/snapshot(_:columns:rows:)``
    /// first, then each batch the terminal parses after it, then
    /// ``TerminalMirrorUpdate/resized(columns:rows:)`` whenever the terminal
    /// is resized, in order, with nothing lost or repeated. It is called with
    /// the terminal locked, from whichever thread feeds it (the snapshot can
    /// come from this call): copy what it needs and return, and never call
    /// back into the terminal.
    ///
    /// A batch can end in the middle of an escape sequence or a UTF-8
    /// character. A snapshot taken then would be followed by the rest of it,
    /// so the snapshot waits for the end of the first batch that leaves the
    /// parser with nothing partial, and nothing is delivered before it. It
    /// waits at most `groundWait`: a program stuck in a sequence, such as an
    /// OSC it never ends, gets its snapshot then, and the mirror may show the
    /// rest of that one sequence as text.
    ///
    /// Batches can be large: up to the reader's coalescing limit under a
    /// flood. Keep the handler to copying them out.
    ///
    /// Only bytes fed through the view are mirrored. Changes the host makes
    /// to the terminal in other ways, such as clearing the scrollback, are
    /// not: start a new mirror after them.
    public nonisolated func startMirror(
        scrollback: Int,
        groundWait: TimeInterval = 1,
        _ handler: @escaping @Sendable (TerminalMirrorUpdate) -> Void
    ) -> TerminalMirrorSubscription {
        renderOwner.startMirror(scrollback: scrollback, groundWait: groundWait, handler)
    }
}

/// The mirrors of one terminal view.
///
/// Every field is read and written with the terminal lock held, which is
/// what makes the unchecked conformance sound.
final class TerminalMirrors: @unchecked Sendable {
    private final class Entry {
        let id: UInt64
        let scrollback: Int
        let handler: @Sendable (TerminalMirrorUpdate) -> Void
        var started = false
        var cancelled = false

        init(id: UInt64, scrollback: Int, handler: @escaping @Sendable (TerminalMirrorUpdate) -> Void) {
            self.id = id
            self.scrollback = scrollback
            self.handler = handler
        }
    }

    /// Whether any mirror runs. The feed path reads only this when none does.
    private(set) var isActive = false
    private var entries: [Entry] = []
    private var nextID: UInt64 = 0
    /// A resize during a parse, told after that batch's output.
    private var resizePending = false

    /// Adds a mirror and, when the parser holds nothing partial, gives it its
    /// snapshot. Call with the terminal lock held.
    func start(_ terminal: Terminal, scrollback: Int,
               handler: @escaping @Sendable (TerminalMirrorUpdate) -> Void) -> UInt64 {
        nextID &+= 1
        let entry = Entry(id: nextID, scrollback: max(0, scrollback), handler: handler)
        entries.append(entry)
        isActive = true
        if terminal.mirrorResized == nil {
            terminal.mirrorResized = { [weak self] terminal in
                self?.terminalResized(terminal)
            }
        }
        // Mid-parse the parser's state isn't stored yet: the end of the batch
        // decides.
        if !terminal.mirrorIsParsing && terminal.mirrorParserIsGround {
            entry.started = true
            handler(.snapshot(terminal.mirrorSnapshot(scrollback: entry.scrollback),
                              columns: terminal.cols, rows: terminal.rows))
        }
        return entry.id
    }

    /// Gives a mirror still waiting for the parser its snapshot now, whatever
    /// the parser holds. Call with the terminal lock held, outside a parse.
    func startNow(_ id: UInt64, _ terminal: Terminal) {
        guard !terminal.mirrorIsParsing,
              let entry = entries.first(where: { $0.id == id }),
              !entry.started, !entry.cancelled else { return }
        entry.started = true
        entry.handler(.snapshot(terminal.mirrorSnapshot(scrollback: entry.scrollback),
                                columns: terminal.cols, rows: terminal.rows))
    }

    /// Whether a mirror has had its snapshot. Call with the terminal lock held.
    func hasStarted(_ id: UInt64) -> Bool {
        entries.first(where: { $0.id == id })?.started ?? true
    }

    /// Removes a mirror. Call with the terminal lock held.
    func remove(_ id: UInt64) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].cancelled = true
        entries.remove(at: index)
        isActive = !entries.isEmpty
    }

    /// Tells every mirror about a batch the terminal just parsed. Call with
    /// the terminal lock held, right after the parse.
    func didParse(_ terminal: Terminal, _ bytes: ArraySlice<UInt8>) {
        // A handler may cancel a mirror, its own or another, so this works
        // from a copy and checks each before it calls.
        let current = entries
        var startedBefore: [Entry] = []
        var waiting = false
        for entry in current where !entry.cancelled {
            if entry.started {
                startedBefore.append(entry)
                entry.handler(.output(bytes))
            } else {
                waiting = true
            }
        }
        if waiting && terminal.mirrorParserIsGround {
            var snapshots: [Int: [UInt8]] = [:]
            for entry in current where !entry.started && !entry.cancelled {
                let snapshot = snapshots[entry.scrollback] ?? terminal.mirrorSnapshot(scrollback: entry.scrollback)
                snapshots[entry.scrollback] = snapshot
                entry.started = true
                entry.handler(.snapshot(snapshot, columns: terminal.cols, rows: terminal.rows))
            }
        }
        if resizePending {
            resizePending = false
            for entry in startedBefore where !entry.cancelled {
                entry.handler(.resized(columns: terminal.cols, rows: terminal.rows))
            }
        }
    }

    /// Called by the terminal at the end of each resize, with its lock held.
    private func terminalResized(_ terminal: Terminal) {
        guard isActive else { return }
        if terminal.mirrorIsParsing {
            // The batch's output goes first, then the news.
            resizePending = true
            return
        }
        // A mirror still waiting for its snapshot gets one at the new size.
        for entry in entries where entry.started && !entry.cancelled {
            entry.handler(.resized(columns: terminal.cols, rows: terminal.rows))
        }
    }
}

extension TerminalRenderOwner {
    func startMirror(scrollback: Int, groundWait: TimeInterval,
                     _ handler: @escaping @Sendable (TerminalMirrorUpdate) -> Void) -> TerminalMirrorSubscription {
        guard let terminal = attachedTerminal() else {
            // No terminal yet: a mirror that never hears anything.
            return TerminalMirrorSubscription(cancellation: nil)
        }
        let lock = terminal.terminalLock
        let mirrors = self.mirrors
        let id: UInt64
        if lock.isLockedByCurrentThread {
            id = mirrors.start(terminal, scrollback: scrollback, handler: handler)
        } else {
            id = lock.withLock { mirrors.start(terminal, scrollback: scrollback, handler: handler) }
        }
        // Still waiting for the parser: past `groundWait`, the snapshot goes anyway.
        let waiting = lock.isLockedByCurrentThread ? !mirrors.hasStarted(id) : lock.withLock { !mirrors.hasStarted(id) }
        if waiting {
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0, groundWait)) { [weak mirrors, weak terminal] in
                guard let mirrors, let terminal else { return }
                terminal.terminalLock.withLock { mirrors.startNow(id, terminal) }
            }
        }
        return TerminalMirrorSubscription { [weak mirrors] in
            guard let mirrors else { return }
            if lock.isLockedByCurrentThread {
                mirrors.remove(id)
            } else {
                lock.withLock { mirrors.remove(id) }
            }
        }
    }
}

#endif
#endif
