//
//  TerminalRenderOwner.swift
//  SwiftTerm
//
//  Owns the mutable snapshot and Metal renderer used by one terminal view.
//

#if os(macOS) || os(iOS) || os(visionOS) || os(macCatalyst)
import Foundation
import CoreGraphics

/// The value inputs that one frame preparation consumes.
private struct FramePreparationRequest: Sendable {
    let viewState: FrameViewState
    let pendingSize: FrameTerminalSize?
    let notifyAccessibility: Bool
#if os(macOS)
    let updateScroller: Bool
#endif
}

/// Publishes main-actor frame inputs to the render thread.
///
/// This type stores values only. The render thread takes one value request,
/// releases this lock, and only then enters the render owner and terminal
/// locks. This makes the lock order explicit and prevents mailbox inversion.
final class TerminalRenderMailbox: Sendable {
    private struct State {
        var latestViewState: FrameViewState?
        var pendingSize: FrameTerminalSize?
        var suppressAccessibility = false
        var blinkRows: [Int] = []
#if os(macOS)
        var updateScroller = false
#endif
    }

    private let state = Locked(State())

    func publish (_ viewState: FrameViewState) {
        state.withLock { $0.latestViewState = viewState }
    }

    func queueSize (cols: Int, rows: Int) {
        state.withLock {
            $0.pendingSize = FrameTerminalSize(cols: cols, rows: rows)
        }
    }

    func setAccessibilityNotification (_ shouldNotify: Bool) {
        state.withLock { $0.suppressAccessibility = !shouldNotify }
    }

#if os(macOS)
    func requestScrollerUpdate () {
        state.withLock { $0.updateScroller = true }
    }
#endif

    func publishBlinkRows (_ rows: [Int]) {
        state.withLock { $0.blinkRows = rows }
    }

    func currentBlinkRows () -> [Int] {
        state.withLock { $0.blinkRows }
    }

    fileprivate func takeRequest (viewState explicitViewState: FrameViewState? = nil)
        -> FramePreparationRequest?
    {
        state.withLock { state in
            guard let viewState = explicitViewState ?? state.latestViewState else {
                return nil
            }
#if os(macOS)
            let request = FramePreparationRequest(
                viewState: viewState,
                pendingSize: state.pendingSize,
                notifyAccessibility: !state.suppressAccessibility,
                updateScroller: state.updateScroller)
#else
            let request = FramePreparationRequest(
                viewState: viewState,
                pendingSize: state.pendingSize,
                notifyAccessibility: !state.suppressAccessibility)
#endif
            state.pendingSize = nil
            state.suppressAccessibility = false
#if os(macOS)
            state.updateScroller = false
#endif
            return request
        }
    }
}

/// A copied inspection value used by tests and diagnostics.
struct TerminalRenderSnapshotInspection: Sendable {
    let rowTexts: [String]
    let rowRevisions: [UInt64]
    let cols: Int
    let selectionActive: Bool
    let selectedRows: [Int]
}

/// Retains one terminal session after the lifecycle lock is released.
///
/// The references are immutable. Their mutable terminal state is accessed only
/// while `terminalLock` is held. The session never leaves the owner API.
private final class TerminalRenderSession {
    let terminal: Terminal
    let selection: SelectionService
    let search: SearchService
    let snapshot = TerminalSnapshot()

    init(terminal: Terminal, selection: SelectionService, search: SearchService) {
        self.terminal = terminal
        self.selection = selection
        self.search = search
    }
}

/// State used only by the render domain. Parser and value APIs never take this
/// lock.
private struct TerminalRenderState {
#if canImport(MetalKit)
    var renderer: MetalTerminalRenderer?
    var needsExternalDraw = false
#endif
}

/// The single owner of mutable frame state for one terminal view.
///
/// The lifecycle lock publishes a stable session reference and is released
/// before parsing or rendering. Terminal mutation uses the fair
/// `TerminalLock`. Snapshot and renderer mutation belongs to the active render
/// executor. The lock order is:
///
/// `RenderLoop.frameLock -> render domain -> session lifecycle lock
/// -> TerminalLock`.
final class TerminalRenderOwner: Sendable {
    let mailbox = TerminalRenderMailbox()
    private let session = Locked<TerminalRenderSession?>(nil)
    private let publishedVisibility = Locked(TerminalVisibility.potentiallyVisible)
    private let renderState = Locked(TerminalRenderState())

    @MainActor
    func attach (terminal: Terminal, selection: SelectionService,
                 search: SearchService) {
        let next = TerminalRenderSession(
            terminal: terminal, selection: selection, search: search)
        let retired = session.withLock { current -> TerminalRenderSession? in
            let retired = current
            current = next
            return retired
        }
        let visibility = publishedVisibility.withLock { $0 }
        terminal.terminalLock.withLock {
            terminal.setTerminalVisibility(visibility)
        }
        // Release the old service graph after the lifecycle lock. A service
        // deinitializer can enter TerminalLock to unregister itself.
        withExtendedLifetime(retired) {}
    }

    private func currentSession() -> TerminalRenderSession? {
        session.withLock { $0 }
    }

    private func withRenderState<Result>(
        _ body: (inout TerminalRenderState) throws -> Result
    ) rethrows -> Result {
#if DEBUG
        if let terminal = currentSession()?.terminal {
            precondition(!terminal.terminalLock.isLockedByCurrentThread,
                         "The render domain cannot be entered under TerminalLock")
        }
#endif
        return try renderState.withLock(body)
    }

    /// Feeds one parser batch while this owner retains all mutable terminal
    /// services. The caller can wake the frame driver before and after this
    /// transaction without retaining a view.
    func feed (bytes: ArraySlice<UInt8>) -> Bool? {
        guard let session = currentSession() else { return nil }
        let terminal = session.terminal
        return terminal.terminalLock.withLock {
            session.search.invalidate()
            let selectedContent = session.selection.captureSelectedContent()
            terminal.feed(buffer: bytes)
            if let selectedContent {
                session.selection.clearIfSelectedContentChanged(from: selectedContent)
            }
            return terminal.synchronizedOutputActive
        }
    }

    /// Feeds one borrowed parser batch. The parse finishes before this method
    /// returns, so the caller can release the source storage after the call.
    func feed(borrowedBytes: Span<UInt8>) -> Bool? {
        guard let session = currentSession() else { return nil }
        let terminal = session.terminal
        return terminal.terminalLock.withLock {
            session.search.invalidate()
            let selectedContent = session.selection.captureSelectedContent()
            terminal.feedBorrowed(borrowedBytes)
            if let selectedContent {
                session.selection.clearIfSelectedContentChanged(from: selectedContent)
            }
            return terminal.synchronizedOutputActive
        }
    }

    /// Text variant of ``feed(bytes:)``.
    func feed (text: String) -> Bool? {
        guard let session = currentSession() else { return nil }
        let terminal = session.terminal
        return terminal.terminalLock.withLock {
            session.search.invalidate()
            let selectedContent = session.selection.captureSelectedContent()
            terminal.feed(text: text)
            if let selectedContent {
                session.selection.clearIfSelectedContentChanged(from: selectedContent)
            }
            return terminal.synchronizedOutputActive
        }
    }

    /// Registers user input under the same owner and terminal locks as feed.
    func registerUserInput(_ bytes: [UInt8]) {
        guard let terminal = currentSession()?.terminal else { return }
        precondition(!terminal.terminalLock.isLockedByCurrentThread,
                     "Input cannot be sent from a terminal callback")
        terminal.terminalLock.withLock {
            terminal.registerUserInput(bytes[...])
        }
    }

    func dimensions() -> TerminalDimensions {
        guard let terminal = currentSession()?.terminal else {
            return TerminalDimensions(cols: 0, rows: 0)
        }
        return terminal.terminalLock.withLock {
            TerminalDimensions(cols: terminal.cols, rows: terminal.rows)
        }
    }

    func bufferData(kind: Terminal.BufferKind,
                    encoding: String.Encoding) -> Data {
        guard let terminal = currentSession()?.terminal else { return Data() }
        return terminal.terminalLock.withLock {
            terminal.getBufferAsData(kind: kind, encoding: encoding)
        }
    }

    func updateColorScheme(_ colorScheme: TerminalColorScheme, notify: Bool) {
        guard let terminal = currentSession()?.terminal else { return }
        terminal.terminalLock.withLock {
            terminal.updateColorScheme(colorScheme, notify: notify)
        }
    }

    func notifyColorScheme() {
        guard let terminal = currentSession()?.terminal else { return }
        terminal.terminalLock.withLock {
            terminal.notifyColorScheme()
        }
    }

    func setTerminalVisibility(_ visibility: TerminalVisibility) {
        publishedVisibility.withLock { $0 = visibility }
        guard let terminal = currentSession()?.terminal else { return }
        terminal.terminalLock.withLock {
            terminal.setTerminalVisibility(visibility)
        }
    }

    func stateSnapshot() -> TerminalViewStateSnapshot {
        guard let terminal = currentSession()?.terminal else {
            return TerminalViewStateSnapshot(
                dimensions: TerminalDimensions(cols: 0, rows: 0),
                cursor: Position(col: 0, row: 0),
                viewportRow: 0,
                currentBidiState: .default,
                bidiArrowKeySwap: false,
                cursorStyle: .blinkBlock,
                ansi256PaletteStrategy: .base16Lab,
                visibleRows: [])
        }
        return terminal.terminalLock.withLock {
                let buffer = terminal.displayBuffer
                let visibleRows = (0..<terminal.rows).compactMap { row
                    -> TerminalVisibleRowSnapshot? in
                    let lineIndex = buffer.yDisp + row
                    guard lineIndex >= 0, lineIndex < buffer.lines.count else {
                        return nil
                    }
                    let line = buffer.lines[lineIndex]
                    let text = terminal.translateBufferLineToString(
                        buffer: buffer, line: lineIndex, start: 0, end: -1)
                        .replacingOccurrences(of: "\u{0}", with: " ")
                    return TerminalVisibleRowSnapshot(
                        row: row,
                        text: text,
                        isWrapped: line.isWrapped,
                        bidiState: line.bidiState,
                        cellWidths: (0..<terminal.cols).map {
                            Int(line[$0].width)
                        })
                }
                return TerminalViewStateSnapshot(
                    dimensions: TerminalDimensions(
                        cols: terminal.cols, rows: terminal.rows),
                    cursor: Position(col: buffer.x, row: buffer.y),
                    viewportRow: buffer.yDisp,
                    currentBidiState: terminal.currentBidiState,
                    bidiArrowKeySwap: terminal.bidiArrowKeySwap,
                    cursorStyle: terminal.options.cursorStyle,
                    ansi256PaletteStrategy: terminal.ansi256PaletteStrategy,
                    visibleRows: visibleRows)
        }
    }

    func semanticPromptRow(searchingUpward: Bool) -> Int? {
        guard let terminal = currentSession()?.terminal else { return nil }
        return terminal.terminalLock.withLock {
            guard !terminal.isCurrentBufferAlternate else { return nil }
            let buffer = terminal.buffer
            let start = buffer.yDisp
            if searchingUpward {
                guard start > 0 else { return nil }
                for row in stride(from: start - 1, through: 0, by: -1) {
                    if terminal.semanticRowKind(at: row) == .initial {
                        return row
                    }
                }
            } else if start + 1 < buffer.lines.count {
                for row in (start + 1)..<buffer.lines.count {
                    if terminal.semanticRowKind(at: row) == .initial {
                        return row
                    }
                }
            }
            return nil
        }
    }

    func ansi256PaletteStrategy() -> Ansi256PaletteStrategy {
        guard let terminal = currentSession()?.terminal else { return .base16Lab }
        return terminal.terminalLock.withLock {
            terminal.ansi256PaletteStrategy
        }
    }

    func setAnsi256PaletteStrategy(_ strategy: Ansi256PaletteStrategy) {
        guard let terminal = currentSession()?.terminal else { return }
        terminal.terminalLock.withLock {
            terminal.ansi256PaletteStrategy = strategy
            terminal.updateFullScreen()
        }
    }

    func maximumBidiParagraphRows() -> Int {
        guard let terminal = currentSession()?.terminal else { return 1 }
        return terminal.terminalLock.withLock {
            terminal.options.maximumBidiParagraphRows
        }
    }

    func setMaximumBidiParagraphRows(_ rows: Int) {
        guard let terminal = currentSession()?.terminal else { return }
        terminal.terminalLock.withLock {
            terminal.options.maximumBidiParagraphRows = max(1, rows)
            terminal.updateFullScreen()
        }
    }

    /// Prepares and draws one detached-surface frame. Only the checked main
    /// effects value leaves the render owner.
    func renderPublishedFrame () -> MainFrameEffects? {
        guard let request = mailbox.takeRequest() else { return nil }
        guard let prepared = prepareFrame(request) else { return nil }
#if canImport(MetalKit)
        if prepared.needsMetalDisplay && metalNeedsExternalDraw {
            renderMetal()
        }
#endif
        return prepared.mainEffects
    }

    @MainActor
    func prepareFrame (viewState: FrameViewState) -> TerminalView.PreparedFrame? {
        guard let request = mailbox.takeRequest(viewState: viewState) else { return nil }
        return prepareFrame(request)
    }

    private func prepareFrame (_ request: FramePreparationRequest)
        -> TerminalView.PreparedFrame?
    {
        withRenderState { renderState in
        guard let session = currentSession() else { return nil }
        let terminal = session.terminal
#if canImport(MetalKit)
        let renderer = renderState.renderer
        let metalActive = renderer != nil
#else
        let metalActive = false
#endif

        var update: TerminalView.PreparedFrame? = terminal.terminalLock.withLock {
            let resizedTo = applyPendingSize(
                request.pendingSize,
                cellPixelWidth: request.viewState.cellPixelWidth,
                cellPixelHeight: request.viewState.cellPixelHeight,
                terminal: terminal,
                selection: session.selection, search: session.search)
            let capturedScrollPosition = Self.scrollPosition(terminal)
#if os(macOS)
            let scrollerState = request.updateScroller
                ? Self.scrollerState(terminal)
                : nil
#endif
            let selectionState = SnapshotSelectionState(selection: session.selection)
            guard session.snapshot.refresh(
                terminal: terminal,
                viewState: request.viewState,
                selection: selectionState,
                deferBidiTypesetting: true) == .refreshed else {
                guard let resizedTo else { return nil }
                var frozen = TerminalView.PreparedFrame(
                    region: nil,
                    rangeChanged: nil,
                    notifyAccessibility: false,
                    needsMetalDisplay: metalActive,
                    cursor: session.snapshot.cursor,
                    cursorRowCount: session.snapshot.rowCount,
                    scrollPosition: capturedScrollPosition)
                frozen.resizedTo = (cols: resizedTo.cols, rows: resizedTo.rows)
#if os(macOS)
                frozen.scroller = scrollerState
#endif
                return frozen
            }

            let buffer = terminal.displayBuffer
            var result: TerminalView.PreparedFrame
            if let (rowStart, rowEnd) = terminal.getUpdateRange() {
                terminal.clearUpdateRange()
                let changed = request.viewState.notifyUpdateChanges
                    ? (start: rowStart, end: rowEnd)
                    : nil
                let region: CGRect

#if os(macOS)
                var redrawStart = rowStart
                var redrawEnd = rowEnd
                if !buffer.lines.isEmpty, rowStart >= 0, rowEnd >= rowStart,
                   rowEnd < terminal.rows {
                    let maxRow = buffer.lines.count - 1
                    let absoluteStart = max(0, min(buffer.yDisp + rowStart, maxRow))
                    let absoluteEnd = max(
                        absoluteStart,
                        min(buffer.yDisp + rowEnd, maxRow))
                    let dependencies = TerminalBidi.renderingDependencyRange(
                        rows: absoluteStart...absoluteEnd,
                        buffer: buffer,
                        maximumRows: terminal.options.maximumBidiParagraphRows)
                    redrawStart = max(0, dependencies.lowerBound - buffer.yDisp)
                    redrawEnd = min(
                        terminal.rows - 1,
                        dependencies.upperBound - buffer.yDisp)
                }

                if buffer.yDisp != buffer.yBase {
                    region = request.viewState.viewBounds
                } else {
                    let cellHeight = request.viewState.cellDimension.height
                    let width = request.viewState.viewBounds.width
                    var dirtyRegion = CGRect(
                        x: 0,
                        y: request.viewState.viewFrameHeight -
                            (cellHeight + CGFloat(redrawEnd) * cellHeight),
                        width: width,
                        height: CGFloat(redrawEnd - redrawStart + 1) * cellHeight)
                    if redrawEnd == terminal.rows - 1 {
                        dirtyRegion = CGRect(
                            x: 0, y: 0, width: width,
                            height: dirtyRegion.height + dirtyRegion.origin.y)
                    } else {
                        let newY = max(0, dirtyRegion.origin.y - cellHeight)
                        dirtyRegion = CGRect(
                            x: 0, y: newY, width: width,
                            height: dirtyRegion.maxY - newY)
                    }
                    region = dirtyRegion
                }
#else
                region = request.viewState.viewBounds
#endif
                session.snapshot.cgRegion = region
                session.snapshot.rangeChanged = changed
                result = TerminalView.PreparedFrame(
                    region: region,
                    rangeChanged: changed,
                    notifyAccessibility: request.notifyAccessibility,
                    needsMetalDisplay: metalActive,
                    cursor: session.snapshot.cursor,
                    cursorRowCount: session.snapshot.rowCount,
                    scrollPosition: capturedScrollPosition)
            } else if session.snapshot.appearanceChanged {
                let region = request.viewState.viewBounds
                session.snapshot.cgRegion = region
                session.snapshot.rangeChanged = nil
                result = TerminalView.PreparedFrame(
                    region: region,
                    rangeChanged: nil,
                    notifyAccessibility: false,
                    needsMetalDisplay: metalActive,
                    cursor: session.snapshot.cursor,
                    cursorRowCount: session.snapshot.rowCount,
                    scrollPosition: capturedScrollPosition)
            } else {
                let changed = request.viewState.notifyUpdateChanges
                    ? (start: buffer.yDisp + buffer.y, end: buffer.yDisp + buffer.y)
                    : nil
                session.snapshot.cgRegion = nil
                session.snapshot.rangeChanged = changed
                result = TerminalView.PreparedFrame(
                    region: nil,
                    rangeChanged: changed,
                    notifyAccessibility: false,
                    needsMetalDisplay: metalActive,
                    cursor: session.snapshot.cursor,
                    cursorRowCount: session.snapshot.rowCount,
                    scrollPosition: capturedScrollPosition)
            }
            result.resizedTo = resizedTo.map { (cols: $0.cols, rows: $0.rows) }
#if os(macOS)
            result.scroller = scrollerState
#endif
            return result
        }

        guard update != nil else { return nil }
        session.snapshot.completePendingBidi()
        update?.cursor = session.snapshot.cursor
        let blinkRows = Self.blinkRows(in: session.snapshot)
        mailbox.publishBlinkRows(blinkRows)
        update?.blinkRows = blinkRows
#if canImport(MetalKit)
        prepareMetalSnapshot(renderer: renderer, snapshot: session.snapshot)
#endif
        return update
        }
    }

    private func applyPendingSize (
        _ pending: FrameTerminalSize?,
        cellPixelWidth: Int,
        cellPixelHeight: Int,
        terminal: Terminal,
        selection: SelectionService?,
        search: SearchService?
    ) -> FrameTerminalSize? {
        guard let pending else {
            terminal.updatePixelGeometry(
                cellWidth: cellPixelWidth,
                cellHeight: cellPixelHeight)
            return nil
        }
        guard pending.cols != terminal.cols || pending.rows != terminal.rows else {
            terminal.updatePixelGeometry(
                cellWidth: cellPixelWidth,
                cellHeight: cellPixelHeight)
            return nil
        }
        let interval = Profiling.begin(.frameResize)
        defer { interval.end("cols=%d", pending.cols) }
        selection?.active = false
        terminal.resize(
            cols: pending.cols,
            rows: pending.rows,
            cellWidth: cellPixelWidth,
            cellHeight: cellPixelHeight)
        search?.invalidate()
        return pending
    }

    private static func scrollPosition (_ terminal: Terminal) -> Double {
        let buffer = terminal.displayBuffer
        if terminal.isDisplayBufferAlternate || buffer.yDisp <= 0 {
            return 0
        }
        let maximum = buffer.lines.count - buffer.rows
        if buffer.yDisp >= maximum {
            return 1
        }
        return Double(buffer.yDisp) / Double(maximum)
    }

#if os(macOS)
    private static func scrollerState (_ terminal: Terminal)
        -> TerminalView.ScrollerState
    {
        let buffer = terminal.displayBuffer
        let canScroll = !terminal.isDisplayBufferAlternate &&
            buffer.hasScrollback && buffer.lines.count > buffer.rows
        let thumb: CGFloat
        if terminal.isDisplayBufferAlternate {
            thumb = 0
        } else if buffer.lines.isEmpty {
            thumb = 1
        } else {
            thumb = max(CGFloat(buffer.rows) / CGFloat(buffer.lines.count), 0.01)
        }
        return TerminalView.ScrollerState(
            isEnabled: canScroll,
            doubleValue: scrollPosition(terminal),
            knobProportion: thumb)
    }
#endif

    private static func blinkRows (in snapshot: TerminalSnapshot) -> [Int] {
        var result: [Int] = []
        for (index, row) in snapshot.rows.enumerated() {
            let limit = min(snapshot.cols, row.line.count)
            if (0..<limit).contains(where: {
                row.line.packedAttribute(at: $0).style.contains(.blink)
            }) {
                result.append(snapshot.firstRow + index)
            }
        }
        return result
    }

    @MainActor
    func withSnapshotForDrawing (
        viewState: FrameViewState,
        _ body: (TerminalSnapshot, SnapshotRenderContext) -> Void
    ) {
        withRenderState { _ in
            guard let snapshot = currentSession()?.snapshot else { return }
            let context = snapshot.renderContext ??
                SnapshotRenderContext(viewState: viewState, snapshot: snapshot)
            body(snapshot, context)
        }
    }

    @MainActor
    func withUpdatedCursor (
        viewState: FrameViewState,
        _ body: (SnapshotCursor?, Int) -> Void
    ) {
        withRenderState { _ in
            guard let session = currentSession() else {
                body(nil, 0)
                return
            }
            let terminal = session.terminal
            _ = terminal.terminalLock.withLock {
                session.snapshot.refresh(
                    terminal: terminal,
                    viewState: viewState,
                    selection: SnapshotSelectionState(selection: session.selection))
            }
            body(session.snapshot.cursor, session.snapshot.rowCount)
        }
    }

    func inspection () -> TerminalRenderSnapshotInspection {
        withRenderState { _ in
            guard let snapshot = currentSession()?.snapshot else {
                return TerminalRenderSnapshotInspection(
                    rowTexts: [], rowRevisions: [], cols: 0,
                    selectionActive: false, selectedRows: [])
            }
            let texts = snapshot.rows.map { row in
                var result = ""
                var column = 0
                while column < min(snapshot.cols, row.line.count) {
                    let cell = row.line.packedView(at: column)
                    result.append(contentsOf: row.text(at: column, cell: cell))
                    column += max(1, Int(cell.width))
                }
                return result
            }
            let selectedRows: [Int]
            if let context = snapshot.renderContext {
                selectedRows = (snapshot.firstRow..<(snapshot.firstRow + snapshot.rowCount))
                    .filter { context.selection.columns(forRow: $0) != nil }
            } else {
                selectedRows = []
            }
            return TerminalRenderSnapshotInspection(
                rowTexts: texts,
                rowRevisions: snapshot.rows.map(\.revision),
                cols: snapshot.cols,
                selectionActive: snapshot.style.selectionActive,
                selectedRows: selectedRows)
        }
    }

#if canImport(MetalKit)
    @MainActor
    func installMetalRenderer (_ renderer: MetalTerminalRenderer,
                               needsExternalDraw: Bool) {
        withRenderState { state in
            precondition(state.renderer == nil,
                         "Install a Metal renderer only after removing the old renderer")
            state.renderer = renderer
            state.needsExternalDraw = needsExternalDraw
        }
    }

    @MainActor
    func replaceMetalRenderer (_ renderer: MetalTerminalRenderer,
                               needsExternalDraw: Bool) -> Bool {
        precondition(currentSession()?.terminal.terminalLock.isLockedByCurrentThread != true,
                     "Metal replacement cannot wait while the terminal lock is held")
        return withRenderState { state in
            guard state.renderer?.waitForIdle() != false else { return false }
            state.renderer = renderer
            state.needsExternalDraw = needsExternalDraw
            return true
        }
    }

    var hasMetalRenderer: Bool {
        withRenderState { $0.renderer != nil }
    }

    var metalNeedsExternalDraw: Bool {
        withRenderState { $0.renderer != nil && $0.needsExternalDraw }
    }

    @MainActor
    func resetMetalCursorBlinkAfterInput() {
        withRenderState { $0.renderer?.resetCursorBlinkAfterInput() }
    }

    var metalHasPreparedSnapshot: Bool {
        withRenderState { $0.renderer?.hasPreparedSnapshot == true }
    }

    func refreshMetalSnapshot (viewState: FrameViewState) -> Bool {
        withRenderState { state in
            guard let session = currentSession(),
                  let renderer = state.renderer else { return false }
            let terminal = session.terminal
            _ = terminal.terminalLock.withLock {
                session.snapshot.refresh(
                    terminal: terminal,
                    viewState: viewState,
                    selection: SnapshotSelectionState(selection: session.selection))
            }
            prepareMetalSnapshot(renderer: renderer, snapshot: session.snapshot)
            return session.snapshot.renderContext != nil
        }
    }

    /// Refreshes and completes one off-screen render while retaining exclusive
    /// ownership of the snapshot. Drawable acquisition happens after the
    /// terminal-lock transaction but before the owner releases its state.
    @MainActor
    func renderMetalSnapshot (viewState: FrameViewState,
                              renderer: MetalTerminalRenderer,
                              target: any MetalRenderTarget) -> Bool {
        withRenderState { _ in
            guard let session = currentSession() else { return false }
            let terminal = session.terminal
            _ = terminal.terminalLock.withLock {
                session.snapshot.refresh(
                    terminal: terminal,
                    viewState: viewState,
                    selection: SnapshotSelectionState(selection: session.selection))
            }
            guard let context = session.snapshot.renderContext else { return false }
            renderer.prepareSnapshotForImmediateDraw(
                snapshot: session.snapshot,
                context: context)
            if target.needsExternalDrawCall {
                renderer.render()
            } else {
                guard let frame = target.acquireDrawableFrame() else {
                    renderer.discardPreparedSnapshot()
                    return false
                }
                renderer.render(frame: frame)
            }
            renderer.discardPreparedSnapshot()
            return true
        }
    }

    private func prepareMetalSnapshot (renderer: MetalTerminalRenderer?,
                                       snapshot: TerminalSnapshot) {
        guard let context = snapshot.renderContext else { return }
        renderer?.prepareSnapshotForImmediateDraw(
            snapshot: snapshot,
            context: context)
    }

    func renderMetal (frame: MetalDrawableFrame? = nil) {
        withRenderState { $0.renderer?.render(frame: frame) }
    }

    func discardPreparedMetalSnapshot () {
        withRenderState { $0.renderer?.discardPreparedSnapshot() }
    }

    @discardableResult
    func waitForMetalIdle () -> Bool {
        withRenderState { $0.renderer?.waitForIdle() ?? true }
    }

    @MainActor
    func removeMetalRenderer () -> Bool {
        precondition(currentSession()?.terminal.terminalLock.isLockedByCurrentThread != true,
                     "Metal teardown cannot wait while the terminal lock is held")
        return withRenderState { state in
            guard state.renderer?.waitForIdle() != false else { return false }
            state.renderer = nil
            state.needsExternalDraw = false
            return true
        }
    }

    var completedMetalRenders: Int {
        withRenderState { $0.renderer?.completedRenders ?? 0 }
    }

    var metalProfileCounters: MetalProfileCounters? {
        withRenderState { $0.renderer?.profileCounters }
    }

    func resetMetalCounters () {
        withRenderState { $0.renderer?.resetRenderCounter() }
    }
#endif
}
#endif
