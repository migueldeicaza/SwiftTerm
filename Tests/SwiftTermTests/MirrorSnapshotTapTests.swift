//
//  MirrorSnapshotTapTests.swift
//
//  TerminalView.startMirror: the snapshot, then every batch the view parses,
//  then resizes, in order, through each of the view's feed paths.
//

#if os(macOS)
import Foundation
import Testing
@testable import SwiftTerm

/// What a mirror heard, in order.
final class MirrorRecorder: Sendable {
    private let heard = Locked<[TerminalMirrorUpdate]>([])

    var handler: @Sendable (TerminalMirrorUpdate) -> Void {
        { [heard] update in heard.withLock { $0.append(update) } }
    }

    var updates: [TerminalMirrorUpdate] {
        heard.withLock { $0 }
    }

    var count: Int {
        heard.withLock { $0.count }
    }
}

enum MirrorTap {
    @MainActor static func makeView(cols: Int = 30, rows: Int = 8) -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        view.resize(cols: cols, rows: rows)
        return view
    }

    /// Feeds through one of the view's three paths: bytes, text, borrowed bytes.
    @MainActor static func feed(_ view: TerminalView, _ bytes: [UInt8], path: Int) {
        switch path % 3 {
        case 0:
            view.feed(byteArray: bytes[...])
        case 1:
            if let text = String(bytes: bytes, encoding: .utf8) {
                view.feed(text: text)
            } else {
                view.feed(byteArray: bytes[...])
            }
        default:
            let slice = bytes[...]
            _ = view.renderOwner.feed(borrowedBytes: slice.span)
        }
    }

    /// A terminal fed what the mirror heard: the snapshot, then each batch.
    /// Nil, with the reason, when the updates break the order.
    static func replay(_ updates: [TerminalMirrorUpdate]) -> (MirrorTestTerminal?, String?) {
        guard case .snapshot(let bytes, let cols, let rows)? = updates.first else {
            return (nil, "the first update is not the snapshot: \(updates.first.map { "\($0)" } ?? "none")")
        }
        let receiver = MirrorTestTerminal(cols: cols, rows: rows)
        receiver.feed(bytes)
        for update in updates.dropFirst() {
            switch update {
            case .output(let batch):
                receiver.feed(Array(batch))
            case .snapshot:
                return (nil, "a second snapshot")
            case .resized(let cols, let rows):
                return (nil, "resized to \(cols)×\(rows)")
            }
        }
        return (receiver, nil)
    }

    @MainActor static func differences(_ view: TerminalView, _ receiver: MirrorTestTerminal,
                                       history: Int) -> [String] {
        view.terminal.terminalLock.withLock {
            MirrorComparison.differences(view.terminal, receiver.terminal, history: history)
        }
    }

    static func outputs(_ updates: [TerminalMirrorUpdate]) -> [[UInt8]] {
        updates.compactMap { update in
            if case .output(let bytes) = update { return Array(bytes) }
            return nil
        }
    }
}

@Suite struct MirrorSnapshotTapTests {
    @MainActor @Test func snapshotFirstThenEveryBatch() {
        let view = MirrorTap.makeView()
        view.feed(text: "before\r\n\u{1b}[31mred")
        let recorder = MirrorRecorder()
        let mirror = view.startMirror(scrollback: 100, recorder.handler)
        #expect(recorder.count == 1, "the snapshot comes from startMirror itself")
        let batches: [[UInt8]] = [Array(" more\r\n".utf8), Array("漢字 ✓".utf8), Array("\u{1b}[m done".utf8)]
        for (index, batch) in batches.enumerated() {
            MirrorTap.feed(view, batch, path: index)
        }
        let updates = recorder.updates
        #expect(MirrorTap.outputs(updates) == batches)
        let (receiver, problem) = MirrorTap.replay(updates)
        #expect(problem == nil, "\(problem ?? "")")
        if let receiver {
            let differences = MirrorTap.differences(view, receiver, history: 100)
            #expect(differences.isEmpty, "\(differences.prefix(6))")
        }
        mirror.cancel()
    }

    /// The recorded session, with the mirror started at many points: inside
    /// escape sequences and UTF-8 characters, and between batches, fed
    /// through all three feed paths.
    @MainActor @Test func streamThroughTheViewFromManyPoints() {
        let bytes = MirrorRecording.session
        var splits = Set(stride(from: 0, through: bytes.count, by: 29))
        for (index, byte) in bytes.enumerated() {
            if byte == 0x1b {
                splits.insert(index + 1)
                splits.insert(index + 2)
            } else if byte >= 0xc0 {
                splits.insert(index + 1)
            }
        }
        var failures: [String] = []
        for split in splits.sorted() where split <= bytes.count {
            let view = MirrorTap.makeView()
            MirrorTap.feed(view, Array(bytes[0..<split]), path: split)
            let recorder = MirrorRecorder()
            let mirror = view.startMirror(scrollback: 40, recorder.handler)
            var startedAfter = recorder.count > 0 ? -1 : nil as Int?
            var batches: [[UInt8]] = []
            var index = split
            let sizes = [1 + split % 6, 11, 2, 37]
            while index < bytes.count {
                let end = min(bytes.count, index + sizes[batches.count % sizes.count])
                let batch = Array(bytes[index..<end])
                batches.append(batch)
                MirrorTap.feed(view, batch, path: split + batches.count)
                if startedAfter == nil && recorder.count > 0 {
                    startedAfter = batches.count - 1
                }
                index = end
            }
            let updates = recorder.updates
            guard let startedAfter else {
                failures.append("split \(split): no snapshot")
                continue
            }
            // Every batch after the one that ended at ground, and none before.
            let expected = Array(batches[(startedAfter + 1)...])
            if MirrorTap.outputs(updates) != expected {
                failures.append("split \(split): \(MirrorTap.outputs(updates).count) batches heard, "
                                + "\(expected.count) expected")
                continue
            }
            let (receiver, problem) = MirrorTap.replay(updates)
            if let problem {
                failures.append("split \(split): \(problem)")
            } else if let receiver {
                let differences = MirrorTap.differences(view, receiver, history: 40)
                if !differences.isEmpty {
                    failures.append("split \(split): \(differences.prefix(3))")
                }
            }
            mirror.cancel()
            if failures.count >= 5 { break }
        }
        #expect(failures.isEmpty, "\(failures)")
    }

    @MainActor @Test func snapshotWaitsForTheParserToBeAtGround() {
        let cases: [(name: String, pieces: [[UInt8]])] = [
            ("inside a CSI", [Array("\u{1b}[3".utf8), Array("1".utf8), Array("mred".utf8)]),
            ("inside a UTF-8 character", [[0xe6], [0xbc], [0xa2, 0x41]]),
            ("inside an OSC", [Array("\u{1b}]2;ti".utf8), Array("tle\u{1b}".utf8), Array("\\after".utf8)]),
            ("inside a DCS", [Array("\u{1b}P$q".utf8), Array("m\u{1b}".utf8), Array("\\x".utf8)]),
        ]
        for (name, pieces) in cases {
            let view = MirrorTap.makeView()
            view.feed(byteArray: pieces[0][...])
            let recorder = MirrorRecorder()
            let mirror = view.startMirror(scrollback: 10, recorder.handler)
            #expect(recorder.count == 0, "\(name): nothing until the parser is at ground")
            for piece in pieces.dropFirst().dropLast() {
                view.feed(byteArray: piece[...])
                #expect(recorder.count == 0, "\(name): still part way")
            }
            view.feed(byteArray: pieces.last![...])
            #expect(recorder.count == 1, "\(name): the snapshot, and no output before it")
            view.feed(text: "z")
            let updates = recorder.updates
            #expect(MirrorTap.outputs(updates) == [Array("z".utf8)], "\(name)")
            let (receiver, problem) = MirrorTap.replay(updates)
            #expect(problem == nil, "\(name): \(problem ?? "")")
            if let receiver {
                let differences = MirrorTap.differences(view, receiver, history: 10)
                #expect(differences.isEmpty, "\(name): \(differences.prefix(4))")
            }
            mirror.cancel()
        }
    }

    /// A program stuck in a sequence it never ends still gets its snapshot,
    /// once `groundWait` has passed, and the mirror carries on from there.
    @MainActor @Test func aSequenceThatNeverEndsWaitsOnlySoLong() async {
        let view = MirrorTap.makeView()
        view.feed(text: "before\r\n")
        view.feed(byteArray: Array("\u{1b}]2;never ends".utf8)[...])
        let recorder = MirrorRecorder()
        let mirror = view.startMirror(scrollback: 10, groundWait: 0.05, recorder.handler)
        #expect(recorder.count == 0, "it waits a moment first")
        let deadline = ContinuousClock.now + .seconds(30)
        while recorder.count == 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(recorder.count == 1, "the snapshot, once the wait is over")
        // The program ends its sequence at last: both sides go on alike.
        view.feed(text: "\u{07}after")
        let (receiver, problem) = MirrorTap.replay(recorder.updates)
        #expect(problem == nil, "\(problem ?? "")")
        if let receiver {
            let rows = view.terminal.terminalLock.withLock { (0..<2).map { view.terminal.getLine(row: $0)?.translateToString(trimRight: true) } }
            #expect(rows == (0..<2).map { receiver.terminal.getLine(row: $0)?.translateToString(trimRight: true) })
            #expect(rows == ["before", "after"])
        }
        mirror.cancel()
    }

    @MainActor @Test func cancelStopsDelivery() {
        let view = MirrorTap.makeView()
        #expect(!view.renderOwner.mirrors.isActive, "no mirror: the feed path checks one flag")
        let recorder = MirrorRecorder()
        let mirror = view.startMirror(scrollback: 10, recorder.handler)
        #expect(view.renderOwner.mirrors.isActive)
        view.feed(text: "a")
        #expect(recorder.count == 2)
        mirror.cancel()
        #expect(!view.renderOwner.mirrors.isActive)
        view.feed(text: "b")
        view.resize(cols: 20, rows: 5)
        #expect(recorder.count == 2, "nothing after cancel")
        mirror.cancel()
    }

    @MainActor @Test func releasingTheSubscriptionCancels() {
        let view = MirrorTap.makeView()
        let recorder = MirrorRecorder()
        do {
            let mirror = view.startMirror(scrollback: 10, recorder.handler)
            view.feed(text: "a")
            withExtendedLifetime(mirror) {}
        }
        view.feed(text: "b")
        #expect(recorder.count == 2)
        #expect(!view.renderOwner.mirrors.isActive)
    }

    @MainActor @Test func cancelFromInsideTheHandler() {
        let view = MirrorTap.makeView()
        let heard = Locked<[TerminalMirrorUpdate]>([])
        let box = Locked<TerminalMirrorSubscription?>(nil)
        let subscription = view.startMirror(scrollback: 10) { update in
            heard.withLock { $0.append(update) }
            if case .output = update {
                // With the terminal locked by this thread: no deadlock.
                box.withLock { $0 }?.cancel()
            }
        }
        box.withLock { $0 = subscription }
        view.feed(text: "a")
        view.feed(text: "b")
        #expect(heard.withLock { $0.count } == 2, "the snapshot and the first batch only")
        #expect(!view.renderOwner.mirrors.isActive)
    }

    @MainActor @Test func severalMirrorsAtOnce() {
        let view = MirrorTap.makeView()
        for line in 0..<20 {
            view.feed(text: "line \(line)\r\n")
        }
        let first = MirrorRecorder()
        let firstMirror = view.startMirror(scrollback: 100, first.handler)
        view.feed(text: "\u{1b}[1;33mbetween\u{1b}[m\r\n")
        let second = MirrorRecorder()
        let secondMirror = view.startMirror(scrollback: 5, second.handler)
        let third = MirrorRecorder()
        let thirdMirror = view.startMirror(scrollback: 5, third.handler)
        thirdMirror.cancel()
        view.feed(text: "after both\r\n漢字")
        for (recorder, history) in [(first, 100), (second, 5)] {
            let (receiver, problem) = MirrorTap.replay(recorder.updates)
            #expect(problem == nil, "\(problem ?? "")")
            if let receiver {
                let differences = MirrorTap.differences(view, receiver, history: history)
                #expect(differences.isEmpty, "history \(history): \(differences.prefix(4))")
            }
        }
        #expect(third.count == 1)
        firstMirror.cancel()
        secondMirror.cancel()
    }

    @MainActor @Test func resizeAfterTheSnapshotComesInOrder() {
        let view = MirrorTap.makeView()
        let recorder = MirrorRecorder()
        let mirror = view.startMirror(scrollback: 10, recorder.handler)
        view.feed(text: "a")
        view.resize(cols: 25, rows: 7)
        view.feed(text: "b")
        let updates = recorder.updates
        guard updates.count == 4 else {
            Issue.record("heard \(updates)")
            return
        }
        guard case .snapshot(_, 30, 8) = updates[0],
              case .output(let a) = updates[1], Array(a) == Array("a".utf8),
              case .resized(25, 7) = updates[2],
              case .output(let b) = updates[3], Array(b) == Array("b".utf8) else {
            Issue.record("out of order: \(updates)")
            return
        }
        mirror.cancel()
    }

    @MainActor @Test func resizeDuringAParseComesAfterItsBatch() {
        // DECCOLM resizes in the middle of the batch that asks for it.
        let view = MirrorTap.makeView()
        view.feed(text: "\u{1b}[?40h")
        let recorder = MirrorRecorder()
        let mirror = view.startMirror(scrollback: 10, recorder.handler)
        view.feed(text: "x\u{1b}[?3hy")
        let updates = recorder.updates
        guard updates.count >= 3,
              case .snapshot = updates[0],
              case .output(let batch) = updates[1], Array(batch) == Array("x\u{1b}[?3hy".utf8),
              case .resized(132, _) = updates[2] else {
            Issue.record("out of order: \(updates)")
            return
        }
        mirror.cancel()
    }

    @MainActor @Test func resizeBeforeAWaitingSnapshotIsNotReported() {
        let view = MirrorTap.makeView()
        view.feed(text: "\u{1b}[")
        let recorder = MirrorRecorder()
        let mirror = view.startMirror(scrollback: 10, recorder.handler)
        view.resize(cols: 22, rows: 6)
        view.feed(text: "m")
        let updates = recorder.updates
        guard updates.count == 1, case .snapshot(_, 22, 6) = updates[0] else {
            Issue.record("heard \(updates)")
            return
        }
        mirror.cancel()
    }
}
#endif

#if os(macOS)
/// TerminalView.frameSize(cols:rows:): a view given that size holds a terminal of exactly that
/// many columns and rows, whatever its size before, and getOptimalFrameSize agrees.
@MainActor
struct TerminalFrameSizeTests {
    @Test func aViewGivenTheFrameSizeHoldsThoseCells() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        for (cols, rows) in [(2, 1), (37, 11), (80, 24), (132, 43)] {
            let size = view.frameSize(cols: cols, rows: rows)
            // Half a point over, as a host gives it so rounding never drops the last cell.
            view.setFrameSize(NSSize(width: size.width + 0.5, height: size.height + 0.5))
            #expect(view.terminalDimensions.cols == cols, "\(cols)x\(rows): \(view.terminalDimensions.cols)")
            #expect(view.terminalDimensions.rows == rows, "\(cols)x\(rows)")
            #expect(view.getOptimalFrameSize().size == size)
        }
        #expect(view.frameSize(cols: 0, rows: -3) == view.frameSize(cols: 1, rows: 1))
    }
}
#endif
