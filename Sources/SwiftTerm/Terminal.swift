//
//  Terminal.swift
//  SwiftTerm
//
//  Created by Miguel de Icaza on 3/27/19.
//  Copyright © 2019 Miguel de Icaza. All rights reserved.
//
// TODO: review every place that sets cursor to use setCursor
// TODO: audit every location to use restrictCursor

import Foundation

/// The light/dark preference represented by the terminal's current color palette.
///
/// This is reported to applications through the color-scheme notification protocol:
/// https://github.com/contour-terminal/contour/blob/master/docs/vt-extensions/color-palette-update-notifications.md
public enum TerminalColorScheme: Equatable {
    case dark
    case light
}

/**
 * The terminal delegate is a protocol that must be implemented by a class
 * that would provide a user interface for the terminal, and it is used by the
 * `Terminal` to notify of important changes on the underlying terminal
 */
public protocol TerminalDelegate: AnyObject {
    /**
     * Invoked to request that the cursor be shown
     */
    func showCursor (source: Terminal)

    /**
     * Invoked to request that the cursor be shown
     */
    func hideCursor (source: Terminal)

    /**
     * This method is invoked when the terminal needs to set the title for the window,
     * a UI toolkit would react by setting the terminal title in the window or any other
     * user visible element.
     *
     * The default implementation does nothing.
     */
    func setTerminalTitle (source: Terminal, title: String)

    /**
     * This method is invoked when the terminal needs to set the title for the minimized icon,
     * a UI toolkit would react by setting the terminal title in the icon or any other
     * user visible element
     *
     * The default implementation does nothing.
     */
    func setTerminalIconTitle (source: Terminal, title: String)

    /**
     * These are various commands that are sent by the client.  They are rare,
     * and if you do not know what to return, just return nil, the terminal
     * will return a suitable value.
     *
     * The response string needs to be suitable for the Xterm CSI Ps ; Ps ; Ps t command
     * see the WindowManipulationCommand enumeration for those that need to return values
     *
     * The default implementation does nothing.
     */
    @discardableResult
    func windowCommand (source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]?
    
    /**
     * This method is invoked when the terminal dimensions have changed in response
     * to an escape sequence that triggers a terminal resize, the user interface toolkit
     * should attempt to accomodate the new window size
     *
     * TODO: This is not wired up
     *
     * The default implementation does nothing.
     */
    func sizeChanged (source: Terminal)
    
    /**
     * Sends the byte data to the client connected to the terminal (in terminal emulation
     * documentation, this is the "host")
     */
    func send (source: Terminal, data: ArraySlice<UInt8>)
    
    // callbacks
    
    /// Callback - the window was scrolled, new yDisplay passed
    /// The default implementation does nothing.
    func scrolled (source: Terminal, yDisp: Int)
    
    /// Callback a newline was generated
    /// The default implementation does nothing.
    func linefeed (source: Terminal)
    
    /// This method is invoked when the buffer changes from Normal to Alternate, or Alternate to Normal
    /// The default implementation does nothing.
    func bufferActivated (source: Terminal)

    /// Invoked when synchronized output mode is toggled on or off.
    /// The default implementation does nothing.
    func synchronizedOutputChanged (source: Terminal, active: Bool)
    
    /// Should raise the bell
    /// The default implementation does nothing.
    func bell (source: Terminal)
    
    /**
     * This is invoked when the selection has changed, or has been turned on.   The status is
     * available in `terminal.selection.active`, and the range relative to the buffer is
     * in `terminal.selection.start` and `terminal.selection.end`
     *
     * The default implementation does nothing.
     */
    func selectionChanged (source: Terminal)
    
    /**
     * This method should return `true` if operations that can read the buffer back should be allowed,
     * otherwise, return false.   This is useful to run some applications that attempt to checksum the
     * contents of the screen (unit tests)
     *
     * The default implementation returns `true`
     */
    func isProcessTrusted (source: Terminal) -> Bool

    /**
     * Returns the cell size in pixels, if known.
     *
     * The default implementation returns nil.
     */
    func cellSizeInPixels (source: Terminal) -> (width: Int, height: Int)?
    
    /**
     * This method is invoked when the `mouseMode` property has changed, and gives the UI
     * a chance to update any tracking capabilities that are required in the toolkit or no longer
     * required to provide the events.
     *
     * The default implementation ignores the mouse change
     */
    func mouseModeChanged (source: Terminal)
    
    /**
     * This method is invoked when a request to change the cursor style has been issued
     * by client application.
     */
    func cursorStyleChanged (source: Terminal, newStyle: CursorStyle)
    
    /**
     * This method is invoked when the client application has issued a command to report
     * its current working directory (this is done with the OSC 7 command).   The value can be
     * read by accessing the `hostCurrentDirectory` property.
     *
     * The default implementaiton does nothing.
     */
    func hostCurrentDirectoryUpdated (source: Terminal)
    
    /**
     * This method is invoked when the client application has issued a command to report
     * its current document (this is done with the OSC 6 command).   The value can be
     * read by accessing the `hostCurrentDocument` property.
     *
     * The default implementaiton does nothing.
     */
    func hostCurrentDocumentUpdated (source: Terminal)
    
    /**
     * This method is invoked when a color in the 0..255 palette has been redefined, if the
     * front-end keeps a cache or uses indexed rendering, it should update the color
     * with the new values.   If the value of idx is nil, this means all the ansi colors changed
     */
    func colorChanged (source: Terminal, idx: Int?)
    
    /**
     * The view should try to set the foreground color to the provided color
     */
    func setForegroundColor (source: Terminal, color: Color)
    
    /**
     * The view should try to set the background color to the provided color
     */
    func setBackgroundColor (source: Terminal, color: Color)
    
    /**
     * The view should try to set the cursor color to the provided color.   If color is nil, the view can use a default.
     */
    func setCursorColor (source: Terminal, color: Color?)
    
    /**
     * This should return the current foreground and background colors to
     * report.
     */
    func getColors (source: Terminal) -> (foreground: Color, background: Color)
    
    /**
     * This method is invoked when the client application (iTerm2) has issued a OSC 1337 and
     * SwiftTerm did not handle a handler for it.
     *
     * The default implementaiton does nothing.
     */
    func iTermContent (source: Terminal, content: ArraySlice<UInt8>)
    
    /**
     * This method is invoked when the client application has issued a OSC 52
     * to put data on the clipboard.
     *
     * - Parameters:
     *  - source: identifies the instance of the terminal that sent this request
     *  - content: the data to place on the clipboard
     * The default implementation does nothing.
     */
    func clipboardCopy(source: Terminal, content: Data)
    
    /**
     * This method is invoked when the client application has issued an OSC 52
     * query to read the clipboard contents.
     *
     * Returning the clipboard data allows the terminal application to read it;
     * returning `nil` denies the request.  The host may use this callback to
     * prompt the user for confirmation before providing clipboard data.
     *
     * The default implementation returns `nil` (denying the request for security).
     *
     * - Parameter source: identifies the instance of the terminal that sent this request
     * - Returns: the current clipboard contents, or `nil` to deny the request
     */
    func clipboardRead(source: Terminal) -> Data?
    
    /**
     * Invoked when client application issues OSC 777 to show notification.
     *
     * The default implementation does nothing.
     * - Parameters:
     *  - source: identifies the instance of the terminal that sent this request
     *  - title: the title to show for the notification
     *  - body: the body of the notification
     */
    func notify(source: Terminal, title: String, body: String)

    /**
     * Invoked when the client application issues OSC 9;4 to report progress.
     *
     * The default implementation does nothing.
     * - Parameters:
     *  - source: identifies the instance of the terminal that sent this request
     *  - report: the parsed progress report
     */
    func progressReport(source: Terminal, report: Terminal.ProgressReport)
    
    /**
     * Invoked to create an image from an RGBA buffer at the current cursor position
     *
     * The default implementation does nothing.
     * - Parameters:
     *  - source: identifies the instance of the terminal that sent this request
     *  - bytes: Image buffer in RGBA format, using 8 bits per channel.
     *  - width: the width in pixels of the image
     *  - height: the height in pixels of the image
     */
    func createImageFromBitmap (source: Terminal, bytes: inout [UInt8], width: Int, height: Int)
    
    /**
     * Invoked to create an image from a byte blob that might be encoded in one of the various
     * compressed file formats (unlike the other option that gets an RGBA buffer already decoded).
     * It also included requests for the desired dimensions.
     * - Parameters:
     *  - source: identifies the instance of the terminal that sent this request
     *  - data: Binary blob containing the image data, which is typically encoded as a PNG or JPEG file
     *  - widthRequest: the width requested, it contains an enumeration describing what the request was
     *  - height: the height requested, it contains an enumeration describing what the request was
     *  - preserveAspectRatio: if set, one of the dimensions will track the hardcoded setting set for the other.
     */
    func createImage (source: Terminal, data: Data, width: ImageSizeRequest, height: ImageSizeRequest, preserveAspectRatio: Bool)
}

/// Enumeration passed to the TerminalDelegate.createImage to configure
/// the desired values for width and height.
public enum ImageSizeRequest: Sendable {
    /// Make the best decision based on the image data
    case auto
    /// Occupy exactly the number of cells
    case cells(Int)
    /// Occupy exactly the pixels listed
    case pixels(Int)
    /// Occupy a percentange size relative to the dimension of the visible region
    case percent(Int)
}

public protocol TerminalImage {
    /// The width of the image in pixels
    var pixelWidth: Int { get }
    /// The height of the image in pixels
    var pixelHeight: Int { get }
    
    /// Column where the image was attached
    var col: Int { get set }
}

/**
 * The `Terminal` class provides the terminal emulation engine, and can be used to feed data to the
 * terminal emulator.   Typically users will intereact with a higher-level implementation that provides a
 * UI toolkit-specific rendering and connects the input to the UI toolkit.
 *
 * A front-end would draw the contents of the terminal, and take input from the user, which is in turn
 * either mapped to one of the public APIs here, or if it is user input is passed to the `feed`  methods here.
 *
 * The terminal is also connected to a backend that is conneted to the client, and data from this
 * client is fed into the emulator by calling the `sendResponse method`
 *
 * The behavior of the terminal is configured by implementing the `TerminalDelegate` protocol
 * that is provided in the constructor call.
 */
open class Terminal {
    public enum ProgressReportState: Int, Sendable {
        case remove = 0
        case set = 1
        case error = 2
        case indeterminate = 3
        case pause = 4
    }

    public struct ProgressReport: Equatable, Sendable {
        public let state: ProgressReportState
        public let progress: UInt8?

        public init(state: ProgressReportState, progress: UInt8?) {
            self.state = state
            self.progress = progress
        }
    }

    let MINIMUM_COLS = 2
    let MINIMUM_ROWS = 1

    /// Guards all mutable terminal state. `Terminal` methods do not acquire
    /// this lock themselves; callers that feed, render, or query the terminal
    /// synchronize through this object.
    public let terminalLock = TerminalLock()
    
    /// The current terminal columns (counting from 1)
    public var cols: Int { _cols }
    private(set) var _cols: Int = 80
    
    /// The current terminal rows (counting from 1)
    public var rows: Int { _rows }
    private(set) var _rows: Int = 25
    var tabStopWidth : Int = 8
    
    /// Terminal configuration options.
    /// Setup(isReset:) method should be called to apply changes
    public var options: TerminalOptions {
        get { _options }
        set { _options = newValue }
    }
    private var _options: TerminalOptions
    private let defaultCursorStyle: CursorStyle
    
    // Selection services attached to this terminal.  The views own them; a
    // `SelectionService` owns its terminal, so this side must not retain, or the
    // two would form a cycle.
    //
    // This used to be an array of `weak` boxes, which was the single most
    // expensive weak reference left in the parser: on the profiled flood it cost
    // 1 155 ms of the parse thread — 551 ms `swift_weakLoadStrong`, 540 ms
    // `swift_weakCopyInit` (iterating copied each box) and 64 ms destroying
    // them — to notify a selection that was almost always inactive and returned
    // immediately. See Docs/io-cpu-profile.md §3.2(b) and §8.
    //
    // Two changes replace it. The registry no longer holds `weak`: entries are
    // `unowned(unsafe)` and `SelectionService.deinit` removes its own, so a slot
    // can never outlive its service. And `activeSelectionCount` lets the scroll
    // path skip the registry entirely in the overwhelmingly common case where
    // nothing is selected.
    private struct SelectionSlot {
        unowned(unsafe) let value: SelectionService
    }
    private var selections: [SelectionSlot] = []

    /// Number of attached selections currently reporting `active`. Maintained by
    /// ``SelectionService`` as its `_active` flag flips, and consulted before the
    /// scroll path touches ``selections`` at all.
    private var activeSelectionCount = 0

    /// Runs `body` under the terminal lock, unless this thread already holds it.
    ///
    /// Registration happens inside a `withLock` block (`AppleTerminalView` builds
    /// its `SelectionService` there), and that same assignment releases the
    /// previous service — so a `deinit` that unconditionally took the lock would
    /// deadlock on re-setup. The lock is a ticket lock and is not re-entrant.
    private func withSelectionRegistry (_ body: () -> Void)
    {
        if terminalLock.isLockedByCurrentThread {
            body ()
        } else {
            terminalLock.withLock (body)
        }
    }

    func register (selection: SelectionService)
    {
        withSelectionRegistry {
            guard !self.selections.contains (where: { $0.value === selection }) else {
                return
            }
            self.selections.append (SelectionSlot (value: selection))
            if selection._active {
                self.activeSelectionCount += 1
            }
        }
    }

    /// Removes a selection from the registry. Called from `SelectionService.deinit`,
    /// which is what makes the `unowned(unsafe)` slots safe: no slot survives its
    /// service.
    func unregister (selection: SelectionService)
    {
        withSelectionRegistry {
            guard let idx = self.selections.firstIndex (where: { $0.value === selection }) else {
                return
            }
            self.selections.remove (at: idx)
            if selection._active {
                self.activeSelectionCount -= 1
            }
        }
    }

    /// Called by ``SelectionService`` when its active state flips, so the scroll
    /// path can decide whether the registry is worth walking.
    func selectionActiveDidChange (nowActive: Bool)
    {
        activeSelectionCount += nowActive ? 1 : -1
    }

    /// Registry size, for tests. A slot outliving its service would be a
    /// use-after-free, so this is worth asserting on.
    var testingSelectionCount: Int { selections.count }

    /// Active-selection count, for tests. Drift here silently stops selections
    /// from tracking in-place scrolls.
    var testingActiveSelectionCount: Int { activeSelectionCount }

    /// Notifies attached selections that `lines` rows were shifted up in place
    /// within the absolute row range `top...bottom`.
    func selectionsAdjustForInPlaceScroll (top: Int, bottom: Int, lines: Int)
    {
        // Hot path: every scrolled line lands here. An inactive selection would
        // return immediately from `adjustForInPlaceScroll` anyway, so the whole
        // walk is skippable when nothing is selected.
        guard activeSelectionCount > 0, lines != 0 else {
            return
        }
        let currentSelections = selections
        for entry in currentSelections {
            entry.value.adjustForInPlaceScroll (top: top, bottom: bottom, lines: lines)
        }
    }

    /// Notifies attached selections that rows `top...bottom` were shifted only
    /// within the columns `left...right` (margin mode).
    func selectionsInvalidateForColumnRestrictedScroll (top: Int, bottom: Int, left: Int, right: Int)
    {
        guard activeSelectionCount > 0 else {
            return
        }
        let currentSelections = selections
        for entry in currentSelections {
            entry.value.invalidateForColumnRestrictedScroll (top: top, bottom: bottom,
                                                              left: left, right: right)
        }
    }

    // The current buffers
    private let cellArena: CellArena
    var normalBuffer, altBuffer: Buffer
    /**
     * Returns the active buffer (either the normal buffer or the alternative buffer)
     */
    public var buffer: Buffer { _buffer }
    private(set) var _buffer: Buffer

    /// Controls whether primary pointer clicks are routed to an active OSC 133
    /// semantic prompt. Views use this when deciding whether a click should
    /// take precedence over local selection, links, or ordinary mouse reports.
    public var semanticPromptClickBehavior: SemanticPromptClickBehavior = .enabled

    /// The click mode most recently advertised by the active buffer's OSC 133 shell.
    public var semanticPromptClickMode: SemanticPromptClickMode {
        buffer.semanticClickMode
    }

    /// How long DECSET 2026 may hold the display before the valve opens.
    ///
    /// Settable for tests only: one needs it short enough to observe inside a
    /// blocked main queue, another needs it long enough not to fire in the
    /// middle of an unrelated assertion. Both were timing-fragile against a
    /// fixed 1 s.
    var synchronizedOutputTimeoutSeconds: TimeInterval = 1.0
    public private(set) var synchronizedOutputActive: Bool = false
    private var synchronizedOutputTimeoutItem: DispatchWorkItem?

    var displayBuffer: Buffer {
        buffer
    }

    var isDisplayBufferAlternate: Bool {
        isCurrentBufferAlternate
    }
    
    public var isCurrentBufferAlternate: Bool {
        buffer === altBuffer
    }
    
    // Whether the terminal is operating in application keypad mode
    var applicationKeypad : Bool = false
    
    // Whether the terminal is operating in application cursor mode
    public var applicationCursor : Bool = false

    /// Whether DEC reverse-screen mode (DECSCNM) is active.
    private(set) var reverseColors: Bool = false

    private struct KeyboardModeState: Sendable {
        var flags: KittyKeyboardFlags = []
        var stack: [KittyKeyboardFlags] = []
    }

    private static let keyboardModeStackLimit = 16
    private var keyboardModeNormal = KeyboardModeState()
    private var keyboardModeAlt = KeyboardModeState()

    public var keyboardEnhancementFlags: KittyKeyboardFlags {
        let mode = isCurrentBufferAlternate ? keyboardModeAlt : keyboardModeNormal
        return mode.flags
    }
    
    // You can ignore most of the defaults set here, the function
    // reset() will do that again
    var sendFocus: Bool = false

    /// BiDi state that new paragraphs receive.
    public var currentBidiState: BidiPresentationState { _currentBidiState }
    private(set) var _currentBidiState: BidiPresentationState = .default

    /// True when left and right cursor keys follow the resolved paragraph
    /// direction. Hosts can change this while the terminal is running. A reset
    /// restores `options.initialBidiArrowKeySwap`.
    public var bidiArrowKeySwap: Bool = false

    // These properties keep source compatibility with the first BiDi patch.
    public var bidiSupportEnabled: Bool { currentBidiState.supportMode == .implicit }
    public var bidiAutodetectDirection: Bool { currentBidiState.autodetectDirection }
    public var bidiRTLPreference: Bool { currentBidiState.fallbackDirection == .rightToLeft }
    public var bidiBoxMirroring: Bool { currentBidiState.boxMirroring }

    private var savedBidiPrivateModes: [Int: Bool] = [:]
    var cursorHidden : Bool = false
    
    /// Controls the origin mode (DECOM), when set, the screen is limited to the top and bottom margins
    var originMode: Bool = false
    
    /// Controls whether it is possible to set left and right margin modes
    var marginMode: Bool = false
    
    var insertMode: Bool = false
    
    var wraparound: Bool = false

    func setMarginMode(_ value: Bool) {
        marginMode = value
        normalBuffer.setMarginMode(value)
        altBuffer.setMarginMode(value)
    }

    func setInsertMode(_ value: Bool) {
        insertMode = value
        normalBuffer.setInsertMode(value)
        altBuffer.setInsertMode(value)
    }

    func setWraparound(_ value: Bool) {
        wraparound = value
        normalBuffer.setWraparound(value)
        altBuffer.setWraparound(value)
    }

    /// Indicates that the application has toggled bracketed paste mode, which means that when content is pasted into
    /// the terminal, the content will be wrapped in "ESC [ 200 ~" to start, and "ESC [ 201 ~" to end.
    public private(set) var bracketedPasteMode: Bool = false

    /// Tracks DECSET/DECRST private mode 1007 (Alternate Scroll Mode, xterm's "alternateScroll" resource).
    /// When true and the alternate screen buffer is active without an application mouse-tracking mode enabled,
    /// hosts are expected to translate scroll wheel input into cursor up/down key sequences instead of scrolling,
    /// so that full-screen apps that do not read the mouse (e.g. `less`, `vim` without `mouse=a`) still respond
    /// to the scroll wheel. SwiftTerm only tracks the mode's state here; translating wheel events is left to the
    /// host view, which can read this property to decide how to route them.
    /// xterm's own default for this resource is false; we default to true here to match modern terminals
    /// (e.g. Ghostty) that enable it out of the box.
    public private(set) var alternateScrollMode: Bool = true
    /// Whether the running application subscribed to unsolicited color-scheme updates with `CSI ? 2031 h`.
    public private(set) var colorSchemeUpdatesEnabled: Bool = false

    /// The light/dark preference represented by the current terminal palette, as reported to applications that
    /// query it (`CSI ? 996 n`). Defaults to `.dark`; hosts should call `updateColorScheme(_:)` once the initial
    /// palette is installed so a light terminal never reports the wrong preference.
    public private(set) var colorScheme: TerminalColorScheme = .dark
    
    private var charset: [UInt8:String]? = nil
    private var gCharsets: [[UInt8:String]?] = [CharSets.defaultCharset, nil, nil, nil]
    var gcharset: Int = 0
    var reverseWraparound: Bool = false
    weak var tdel: TerminalDelegate?
    private var curAttr: Attribute = CharData.defaultAttr
    /// Arena identifier for `curAttr`. It changes only when SGR state changes.
    private var curStyleID: UInt16 = 0
    /// Erase state derived from `curAttr`, cached at the same boundary.
    private var currentEraseAttribute: Attribute = CharData.defaultAttr
    private var currentEraseBlankCell = PackedCell()
    private var currentEraseSpaceCell = PackedCell(rawValue: UInt64(32) << PackedCell.contentShift)
    var gLevel: UInt8 = 0
    var cursorBlink: Bool = false
    
    /// Whether DECCOLM (`CSI ? 3 h` / `CSI ? 3 l`) may resize the terminal to
    /// 132 or 80 columns. Off by default, matching xterm's `allowC132`
    /// resource: xterm's own `rs2` reset string contains `CSI ? 3 ; 4 l`, so
    /// honouring DECCOLM means anything that resets the terminal — `reset`,
    /// `tput init`, an ssh or tmux session tearing down — silently snaps the
    /// buffer to 80 columns and leaves the rest of the view unused. Worse,
    /// running `reset` to recover re-sends the very sequence that causes it.
    /// An application that genuinely wants the mode can still ask for it with
    /// `CSI ? 40 h`.
    var allow80To132 = false
    
    /// The escape sequence parser driving this terminal.
    ///
    /// Deliberately not public. The parser does not store a reference to the
    /// terminal. The terminal passes itself to each parse operation so parser
    /// dispatch can call terminal methods directly.
    ///
    /// To register a custom OSC handler, use ``registerOscHandler(code:handler:)``.
    private var parser: EscapeSequenceParser

    /// Owns copied OSC observations independently of parser storage.
    private let oscEventDispatcher = TerminalOscEventDispatcher()

    /// The current parser nesting depth. Scroll notifications are delivered
    /// when the outer parse operation finishes.
    private var parseDepth = 0

    /// Whether the current parse operation produced a scroll. Multiple
    /// scrolled lines need only one delegate notification.
    private var hasPendingScrollNotification = false
    var kittyGraphicsState = KittyGraphicsState()
    /// True while either screen holds at least one placement.
    ///
    /// The scrolling paths below run per scrolled line and would otherwise
    /// pay for the placement-store accessor, a dictionary iteration and a
    /// `Set` allocation on every line of every session, image or not. This is
    /// a plain field so the guard is one load. It covers both screens, so it
    /// stays correct when `scroll()` runs while the state points at the other
    /// screen; `updateHasKittyPlacements()` refreshes it after every
    /// insertion or removal in `placementsByKey`.
    var hasKittyPlacements = false
    var kittyAnimationTimerSerial: UInt64 = 0
    
    var refreshStart = Int.max
    var refreshEnd = -1
    var scrollInvariantRefreshStart = Int.max
    var scrollInvariantRefreshEnd = -1
    var userScrolling = false
    var lineFeedMode = false
    
    // We do not implement smooth scrolling here, dubious value, but
    // makes a test bass
    var smoothScroll = false
    
    // Installed colors are the 16 values that can be changed dynamically by the host
    var installedColors: [Color]
    // The blueprint for the colors, computed based on the installed colors
    var defaultAnsiColors: [Color]
    // The active set of colors (based on the blueprint)
    var ansiColors: [Color]
    
    // Control codes provides an API to send either 8bit sequences or 7bit sequences for C0 and C1 depending on the terminal state
    var cc: CC
    
    /// This variable if set, contains an URI representing the host and directory of the process running in the terminal
    /// it is often used by applciations to track the working directory.   It might be nil, or might not be correct, the
    /// contents are entirely under the control of the remote application, and require the terminal to be trusted
    /// (see the `isProcessTrusted` method in the `TerminalDelegate`).  When this is set the
    /// `hostCurrentDirectoryUpdated` method on the delegate is invoked.
    public private(set) var hostCurrentDirectory: String? = nil
    
    /// This variable if set, contains an URI representing the host and current document of the process
    /// running in the terminal.   It might be nil, or might not be correct, the
    /// contents are entirely under the control of the remote application, and require the terminal to be trusted
    /// (see the `isProcessTrusted` method in the `TerminalDelegate`).  When this is set the
    /// `hostCurrentDocumentUpdated` method on the delegate is invoked.
    public private(set) var hostCurrentDocument: String? = nil
    
    /// The current attribute used by the terminal by default
    public var currentAttribute: Attribute {
        get { return curAttr }
    }

    /// Updates the public attribute value and its internal packed forms once.
    /// Print and scroll paths consume the identifiers directly.
    @inline(__always)
    private func setCurrentAttribute(_ attribute: Attribute) {
        guard attribute != curAttr else { return }

        let styleID = cellArena.intern(attribute: attribute)
        let effectiveAttribute = styleID == nil ? CharData.defaultAttr : attribute
        let effectiveStyleID = styleID ?? 0
        let backgroundChanged = effectiveAttribute.bg != curAttr.bg
        curAttr = effectiveAttribute
        curStyleID = effectiveStyleID

        // Erase cells depend only on the background color. Keep the cached
        // cells when another attribute field changes.
        guard backgroundChanged else { return }

        let eraseAttribute = Attribute(fg: CharData.defaultAttr.fg,
                                       bg: effectiveAttribute.bg,
                                       style: CharData.defaultAttr.style)
        let eraseStyleID = eraseAttribute == effectiveAttribute
            ? effectiveStyleID : (cellArena.intern(attribute: eraseAttribute) ?? 0)
        guard let eraseBlank = cellArena.pack(styleID: eraseStyleID, scalar: 0,
                                              widthState: .narrow),
              let eraseSpace = cellArena.pack(styleID: eraseStyleID, scalar: 32,
                                              widthState: .narrow) else {
            preconditionFailure("The terminal created an invalid erase cell")
        }
        currentEraseAttribute = eraseAttribute
        currentEraseBlankCell = eraseBlank
        currentEraseSpaceCell = eraseSpace
    }
    // The requested conformance from DECSCL command
    enum TerminalConformance: Sendable {
        case vt100
        case vt200
        case vt300
        case vt400
        case vt500
    }
    
    // The mouse coordinates can be encoded in a number of ways, and obey to historical
    // upgrades to the protocol, but also attempts at fixing limitations of the different
    // encodings.
    enum MouseProtocolEncoding: Sendable {
        // The default x10 mode is limited to coordinates up to 223.
        // (255-32).   The other modes solve this limitaion
        case x10
        
        // Extends the range of a coordinate to 2015 by using UTF-8 encoding of the
        // coordinate value.   This encoding is troublesome for applications that
        // do not support utf8 input.
        case utf8
        
        // The response uses CSI < ButtonValue ; Px ; Py [Mm]
        case sgr

        // Different response style, with possible ambiguities, not recommended
        case urxvt
        
        // SGR with pixel precision
        case sgrPixel
    }
    
    // The protocol encoding for the terminal
    private var mouseProtocol: MouseProtocolEncoding = .x10

    // This is used to track if we are setting the colors, to prevent a
    // recursive invocation (nativeForegroundColor sets the terminal
    // color, which in turn broadcasts the request for a change)
    var settingFgColor = false, settingBgColor = false, settingCursorColor = false

    /// This tracks the current foreground color for the application.
    public var foregroundColor: Color = Color.defaultForeground {
        didSet {
            if settingFgColor {
                return
            }
            settingFgColor = true
            tdel?.setForegroundColor(source: self, color: foregroundColor)
            settingFgColor = false

            if options.ansi256PaletteStrategy != .xterm {
                rebuildAnsiPalette(notifyDelegate: true)
            }
        }
    }
    /// This tracks the current background color for the application.
    public var backgroundColor: Color = Color.defaultBackground {
        didSet {
            if settingBgColor {
                return
            }
            settingBgColor = true
            tdel?.setBackgroundColor(source: self, color: backgroundColor)
            settingBgColor = false

            if options.ansi256PaletteStrategy != .xterm {
                rebuildAnsiPalette(notifyDelegate: true)
            }
        }
    }

    /// Strategy used to derive the extended 256-color palette (indices 16...255).
    ///
    /// Changing this value rebuilds the active palette immediately and refreshes the UI.
    public var ansi256PaletteStrategy: Ansi256PaletteStrategy {
        get {
            options.ansi256PaletteStrategy
        }
        set {
            if options.ansi256PaletteStrategy == newValue {
                return
            }
            options.ansi256PaletteStrategy = newValue
            rebuildAnsiPalette(notifyDelegate: true)
        }
    }
    
    // This tracks the requested cursor color or nil to use a view-default
    public var cursorColor: Color? = nil {
        didSet {
            if settingCursorColor {
                return
            }
            settingCursorColor = true
            tdel?.setCursorColor(source: self, color: cursorColor)
            settingCursorColor = false
        }
    }
    
    /// Tracks the host view's focus so that enabling focus reporting (DECSET
    /// 1004) can immediately tell the application the current state, the way
    /// xterm does. Defaults to focused.
    var reportedFocusState: Bool = true

    /// Invoke this command when the terminal receives and loses focus
    public func setTerminalFocus(_ focused: Bool) {
        reportedFocusState = focused
        if sendFocus {
            sendFocusReport()
        }
    }

    func sendFocusReport() {
        let data: [UInt8] = cc.CSI + [reportedFocusState ? 0x49 : 0x4f]
        tdel?.send(source: self, data: data[0...])
    }
    
    ///
    /// Represents the mouse operation mode that the terminal is currently using and higher level
    /// implementations should use the functions in this enumeration to determine what events to
    /// send
    public enum MouseMode: Sendable {
        /// No mouse events are reported
        case off
        
        /// X10 Compatibility mode - only sends events in button press
        case x10
        
        /// VT200, also known as Normal Tracking Mode - sends both press and release events
        case vt200
        
        /// ButtonEventTracking - In addition to sending button press and release events, it sends motion events when the button is pressed
        case buttonEventTracking
        
        /// Sends button presses, button releases, and motion events regardless of the button state
        case anyEvent
        
        // Unsupported modes:
        // - vt200Highlight, this can deadlock the terminal
        // - declocator, rarely used
        
        /// Returns true if you should send a button press event (separate from release)
        func sendButtonPress () -> Bool
        {
            self == .vt200 || self == .buttonEventTracking || self == .anyEvent
        }
        
        /// Returns true if you should send the button release event
        func sendButtonRelease () -> Bool
        {
            self != .off
        }
        
        /// Returns true if you should send a motion event when a button is pressed
        func sendButtonTracking () -> Bool
        {
            self == .buttonEventTracking || self == .anyEvent
        }
        
        /// Returns true if you should send a motion event, regardless of button state
        public func sendMotionEvent () -> Bool
        {
            self == .anyEvent
        }
        
        /// Returns true if the modifiers should be encoded
        public func sendsModifiers() -> Bool {
            self == .vt200 || self == .buttonEventTracking || self == .anyEvent
        }
    }
    
    public private(set) var mouseMode: MouseMode = .off {
        didSet {
            tdel?.mouseModeChanged (source: self)
        }
    }

    /// The latest pressure data from the pointer device. Callers must hold
    /// ``terminalLock`` when they read or change this state.
    private(set) var pressureStage = 0
    private(set) var pressure: Float = 0
    private(set) var primaryPointerPressLocation: Position?

    func beginPrimaryPointerPress(at location: Position) {
        terminalLock.preconditionLocked()
        primaryPointerPressLocation = location
    }

    func endPrimaryPointerPress() {
        terminalLock.preconditionLocked()
        primaryPointerPressLocation = nil
    }

    /// Stores one pressure event and returns the press location at deep
    /// pressure (stage 2).
    func updatePressure(stage: Int, pressure: Float) -> Position? {
        terminalLock.preconditionLocked()
        pressureStage = stage
        self.pressure = pressure
        guard stage == 2 else { return nil }
        return primaryPointerPressLocation
    }

    /// Whether the running application has requested shift capture via XTSHIFTESCAPE (`CSI > 1 s`).
    /// When `true`, shift+click is forwarded to the app instead of triggering local text selection.
    public private(set) var mouseShiftCapture: Bool = false

    // The next four variables determine whether setting/querying should be done using utf8 or latin1
    // and whether the values should be set or queried using hex digits, rather than actual byte streams
    var xtermTitleSetUtf = false
    var xtermTitleSetHex = false
    var xtermTitleQueryUtf = false
    var xtermTitleQueryHex = false
    
    var conformance: TerminalConformance = .vt500
    
    /**
     * Returns true if we should respect the left/right margins, which is based on the originMode and marginMode setting
     */
    func usingMargins() ->Bool
    {
        return originMode && marginMode
    }
    
    /// Returns the terminal dimensions 1-based values
    public func getDims () -> (cols: Int,rows: Int)
    {
        return (cols, rows)
    }
    
    public init (delegate: TerminalDelegate, options: TerminalOptions = TerminalOptions.default)
    {
        let cellArena = CellArena()
        self.cellArena = cellArena
        installedColors = Color.terminalAppColors
        defaultAnsiColors = Color.setupDefaultAnsiColors(initialColors: installedColors,
                                                         strategy: options.ansi256PaletteStrategy,
                                                         backgroundColor: Color.defaultBackground,
                                                         foregroundColor: Color.defaultForeground)
        ansiColors = defaultAnsiColors
        tdel = delegate
        self._options = options
        defaultCursorStyle = options.cursorStyle
        _currentBidiState = options.initialBidiState
        bidiArrowKeySwap = options.initialBidiArrowKeySwap
        // This duplicates the setup above, but
        parser = EscapeSequenceParser()
        normalBuffer = Buffer(cols: _cols, rows: _rows, tabStopWidth: tabStopWidth,
                              scrollback: options.scrollback, bidiState: options.initialBidiState,
                              arena: cellArena)
        normalBuffer.fillViewportRows()

        // The alt buffer should never have scrollback.
        // See http://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h2-The-Alternate-Screen-Buffer
        altBuffer = Buffer (cols: _cols, rows: _rows, tabStopWidth: tabStopWidth,
                            scrollback: nil, bidiState: options.initialBidiState, arena: cellArena)
        _buffer = normalBuffer

        cc = CC(send8bit: false)
        
        normalBuffer.terminal = self
        altBuffer.terminal = self

        setupTabStops()

        setup()
    }

    deinit {
        TinyAtom.release(codes: payloadCodes)
    }

    /// Installs the new colors as the default colors and recomputes the
    /// current and ansi palette.   This will not change the UI layer, for that it is better
    /// to call the `installColors` method on `TerminalView`, which will
    /// both call this method, and update the display appropriately.
    ///
    /// - Parameter colors: this should be an array of 16 values that correspond to the 16 ANSI colors,
    /// if the array does not contain 16 elements, it will not do anything
    public func installPalette (colors: [Color])
    {
        if colors.count != 16 {
            return
        }
        installedColors = colors
        rebuildAnsiPalette(notifyDelegate: false)
    }

    private func rebuildAnsiPalette(notifyDelegate: Bool) {
        defaultAnsiColors = Color.setupDefaultAnsiColors(initialColors: installedColors,
                                                         strategy: options.ansi256PaletteStrategy,
                                                         backgroundColor: backgroundColor,
                                                         foregroundColor: foregroundColor)
        ansiColors = defaultAnsiColors
        if notifyDelegate {
            tdel?.colorChanged(source: self, idx: nil)
        }
    }
    
    /// Returns the CharData at the specified column and row from the visible portion of the buffer, these are zero-based
    ///
    /// - Parameter col: column to retrieve, starts at 0
    /// - Parameter row: row to retrieve, starts at 0
    /// - Returns: nil if the col or row are out of bounds, or the CharData contained in that cell otherwise
    ///
    public func getCharData (col: Int, row: Int) -> CharData?
    {
        if col < 0 || col >= cols {
            return nil
        }
        if let l = getLine (row: row) {
            return l [col]
        }
        return nil
    }

    /// Returns the contents of a line as a BufferLine, or nil if the requested line is out of range
    ///
    /// The line is counted  from start of scroll back, not what the terminal has visible right now.
    /// - Parameter row: the row to retrieve, relative to the scroll buffer, not the visible display
    /// - Returns: nil if the col or row are out of bounds, or the BufferLine  otherwise
    public func getLine (row: Int) -> BufferLine? {
        if row < 0 || row >= rows {
            return nil
        }
        return buffer.lines [row + buffer.yDisp]
    }

    /// Returns the contents of a line as a BufferLine counting from the begging of the scroll buffer.
    ///
    /// The line is counted  from start of scroll back, not what the terminal has visible right now.
    /// - Parameter row: the row to retrieve, relative to the scroll buffer, not the visible display
    /// - Returns: nil if the col or row are out of bounds, or the BufferLine  otherwise
    public func getScrollInvariantLine (row: Int) -> BufferLine? {
        if row < buffer.linesTop || row >= buffer.lines.count + buffer.linesTop {
            return nil
        }
        return buffer.lines [row-buffer.linesTop]
    }

    /// Returns the character at the specified column and row, these are zero-based
    /// - Parameter col: column to retrieve, starts at 0
    /// - Parameter row: row to retrieve, starts at 0
    /// - Returns: nil if the col or row are out of bounds, or the Character contained in that cell otherwise
    
    public func getCharacter (col: Int, row: Int) -> Character?
    {
        guard let charData = getCharData(col: col, row: row) else {
            return nil
        }
        return getCharacter(for: charData)
    }
    
    public func resetNormalBuffer() {
        normalBuffer = Buffer(cols: cols, rows: rows, tabStopWidth: tabStopWidth,
                              scrollback: options.scrollback, bidiState: currentBidiState,
                              arena: cellArena)
        normalBuffer.terminal = self

        normalBuffer.fillViewportRows()
        normalBuffer.setupTabStops(tabStopWidth: tabStopWidth)
    }
    
    private func activateNormalBuffer(clearAlt: Bool) {
        if buffer === normalBuffer {
            return
        }
        semanticNoteAlternateScreenSwitch()

        // A full-screen program can sit over thousands of normal-buffer scrollback lines. While
        // that alternate screen is active, window resizes update only what is visible and leave
        // this buffer at its prior grid; otherwise every drag tick reflows hidden history. Pay
        // that cost once, at the final grid, only when the normal buffer becomes visible again.
        resizeNormalBufferToCurrentGridIfNeeded()
        normalBuffer.x = altBuffer.x
        normalBuffer.y = altBuffer.y
        
        // The alt buffer should always be cleared when we switch to the normal
        // buffer. This frees up memory since the alt buffer should always be new
        // when activated.
        
        if clearAlt {
            clearKittyImages(in: altBuffer, isAlternateBuffer: true)
            altBuffer.clear ()
        }
        _buffer = normalBuffer
        kittyGraphicsState.activeIsAlternate = false
        kittyGraphicsDidActivateScreen()
    }
    
    private func activateAltBuffer(fillAttr: Attribute?) {
        if buffer === altBuffer {
            return
        }
        semanticNoteAlternateScreenSwitch()
        altBuffer.x = normalBuffer.x
        altBuffer.y = normalBuffer.y
        
        // Since the alt buffer is always cleared when the normal buffer is
        // activated, we want to fill it when switching to it.
        
        altBuffer.fillViewportRows(attribute: fillAttr)
        _buffer = altBuffer
        kittyGraphicsState.activeIsAlternate = true
        clearKittyImages(in: altBuffer, isAlternateBuffer: true)
        kittyGraphicsDidActivateScreen()
    }

    private func resizeNormalBufferToCurrentGridIfNeeded() {
        guard normalBuffer.cols != cols || normalBuffer.rows != rows else { return }

        let oldCols = normalBuffer.cols
        let dy = normalBuffer.savedY - normalBuffer.y
        normalBuffer.resize(newCols: cols, newRows: rows)
        normalBuffer.savedY = normalBuffer.y + dy
        normalBuffer.setupTabStops(index: oldCols, tabStopWidth: tabStopWidth)
    }
    
    func setupTabStops (index: Int = -1)
    {
        normalBuffer.setupTabStops(index: index, tabStopWidth: tabStopWidth)
        altBuffer.setupTabStops(index: index, tabStopWidth: tabStopWidth)
    }
    
    func resizeBuffers(newColumns: Int, newRows: Int) {
        if buffer !== altBuffer {
            // Correct the savedY cursor to follow changes to y. When the alternate buffer is
            // active, defer this potentially large normal-buffer reflow until it is visible.
            let dy = normalBuffer.savedY - normalBuffer.y
            normalBuffer.resize(newCols: newColumns, newRows: newRows)
            normalBuffer.savedY = normalBuffer.y + dy
        }
        altBuffer.resize (newCols: newColumns, newRows: newRows)
    }
    public func setup (isReset: Bool = false)
    {
        // Sadly a duplicate of much of what lives in init() due to Swift not allowing me to
        // call this
        _cols = max (options.cols, MINIMUM_COLS)
        _rows = max (options.rows, MINIMUM_ROWS)
        
        if isReset {
            resetNormalBuffer()
            activateNormalBuffer(clearAlt: false)
            resetSemanticPromptState(clearingScreenMarks: true)
        } else {
            normalBuffer.resize(newCols: cols, newRows: rows)
            altBuffer.resize(newCols: cols, newRows: rows)
        }
        cursorHidden = false
        
        // modes
        applicationKeypad = false
        applicationCursor = false
        setReverseColors(false)
        originMode = false
        
        setMarginMode(false)
        setInsertMode(false)
        setWraparound(true)
        bracketedPasteMode = false
        alternateScrollMode = true
        colorSchemeUpdatesEnabled = false

        keyboardModeNormal = KeyboardModeState()
        keyboardModeAlt = KeyboardModeState()
        
        // charset'
        gCharsets = [CharSets.defaultCharset, nil, nil, nil]
        charset = gCharsets[0]
        gcharset = 0
        gLevel = 0
        setCurrentAttribute(CharData.defaultAttr)
        
        mouseMode = .off
        mouseShiftCapture = false

        buffer.scrollTop = 0
        buffer.scrollBottom = rows-1
        buffer.marginLeft = 0
        buffer.marginRight = cols-1
        
        cc.send8bit = false
        conformance = .vt500
        
        allow80To132 = false
        
        xtermTitleSetUtf = false
        xtermTitleQueryUtf = false
        
        xtermTitleSetHex = false
        xtermTitleQueryHex = false
        
        activeHyperlink = nil
        cursorBlink = false
        hostCurrentDirectory = nil
        lineFeedMode = options.convertEol
    }

    private func updateKeyboardModeState(_ update: (inout KeyboardModeState) -> Void) {
        if isCurrentBufferAlternate {
            update(&keyboardModeAlt)
        } else {
            update(&keyboardModeNormal)
        }
    }

    private func handleKittyKeyboardProtocol(pars: [Int], collect: cstring) -> Bool {
        guard collect.count == 1, let prefix = collect.first else {
            return false
        }
        switch prefix {
        case UInt8(ascii: "?"):
            sendResponse(cc.CSI, "?\(keyboardEnhancementFlags.rawValue)u")
            return true
        case UInt8(ascii: "="):
            let rawFlags = pars.first ?? 0
            let mode = pars.count > 1 ? pars[1] : 1
            let newFlags = KittyKeyboardFlags(rawValue: rawFlags & KittyKeyboardFlags.knownMask)

            // Per kitty keyboard protocol, only modes 1/2/3 are valid.
            // Ignore invalid modes instead of mutating state.
            guard mode == 1 || mode == 2 || mode == 3 else {
                return true
            }
            updateKeyboardModeState { modeState in
                switch mode {
                case 1:
                    modeState.flags = newFlags
                case 2:
                    modeState.flags.formUnion(newFlags)
                case 3:
                    modeState.flags.subtract(newFlags)
                default:
                    break
                }
            }
            return true
        case UInt8(ascii: ">"):
            let rawFlags = pars.first ?? 0
            let newFlags = KittyKeyboardFlags(rawValue: rawFlags & KittyKeyboardFlags.knownMask)
            updateKeyboardModeState { modeState in
                if modeState.stack.count >= Terminal.keyboardModeStackLimit {
                    modeState.stack.removeFirst()
                }
                modeState.stack.append(modeState.flags)
                modeState.flags = newFlags
            }
            return true
        case UInt8(ascii: "<"):
            let count = max(pars.first ?? 1, 1)
            updateKeyboardModeState { modeState in
                if count > modeState.stack.count {
                    modeState.stack.removeAll()
                    modeState.flags = []
                    return
                }
                for _ in 0..<count {
                    modeState.flags = modeState.stack.removeLast()
                }
            }
            return true
        default:
            return false
        }
    }

    func cmdCsiU(_ pars: [Int], _ collect: cstring) {
        if handleKittyKeyboardProtocol(pars: pars, collect: collect) {
            return
        }

        // Only plain CSI u restores cursor. Unknown CSI ... u forms should be ignored.
        if collect.isEmpty {
            cmdRestoreCursor(pars, collect)
        }
    }
    
    // DCS $ q Pt ST
    // DECRQSS (https://vt100.net/docs/vt510-rm/DECRQSS.html)
    //   Request Status String (DECRQSS), VT420 and up.
    // Response: DECRPSS (https://vt100.net/docs/vt510-rm/DECRPSS.html)
    class DECRQSS : DcsHandler {
        var data: [UInt8]
        // Nested lifetime: this handler is created per DECRQSS sequence and
        // held in the parser's `activeDcsHandler` for the duration of that one
        // sequence, well inside the terminal's life.
        unowned(unsafe) var terminal: Terminal

        public init (terminal: Terminal)
        {
            self.terminal = terminal
            data = []
        }

        func hook (collect: cstring, parameters: [Int],  flag: UInt8)
        {
            data = []
        }
        
        func put (data : ArraySlice<UInt8>)
        {
            for x in data {
                self.data.append(x)
            }
        }
        
        func unhook ()
        {
            let newData = String (bytes: data, encoding: .ascii)
            var ok = 1 // 0 means the request is valid according to docs, but tests expect 0?
            var result: String
            switch (newData) {
            case "\"q": // DECCSA - Set Character Attribute
                result = "\"q"
            case "\"p": // DECSCL - conformance level
                result = "65;1\"p"
            case "r": // DECSTBM - the top and bottom margins
                result = "\(terminal.buffer.scrollTop + 1);\(terminal.buffer.scrollBottom + 1)r"
            case "m": // SGR - the set graphic rendition
                // TODO: report real settings instead of 0m
                result = terminal.curAttr.toSgr ()
            case "s": // DECSLRM - the current left and right margins
                result = "\(terminal.buffer.marginLeft+1);\(terminal.buffer.marginRight+1)s"
            case " q": // DECSCUSR - the set cursor style
                result = "\(terminal.options.cursorStyle.decscusrParameter) q"
            default:
                ok = 0 // this means the request is not valid, report that to the host.
                // invalid: DCS 0 $ r Pt ST (xterm)
                terminal.log ("Unknown DCS + \(newData ?? "")")
                // Do not report 'newData', because it can be exploited
                // see https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=510030
                result = ""

            }
            terminal.sendResponse (terminal.cc.DCS, "\(ok)$r\(result)", terminal.cc.ST)
        }
    }

    /// Registers a synchronous override for one OSC code.
    ///
    /// The override runs before the built-in handler and suppresses that
    /// handler. It runs during parser dispatch while the caller holds
    /// ``terminalLock``. The payload slice is borrowed and is valid only until
    /// the override returns. Copy the bytes if they must outlive the call.
    /// - Parameters:
    ///  - code: the code for the OSC handler to register, no checks are made that this overrides an existing handler
    ///  - handler: the code to invoke when the OSC handler is received.
    public func registerOscHandler (code: Int, handler: @escaping (ArraySlice<UInt8>) -> ())
    {
        parser.oscHandlers [code] = handler
    }

    /// Observes copied OSC events without changing built-in or override behavior.
    ///
    /// Events are delivered asynchronously on a private serial queue in parser
    /// encounter order. This includes OSC codes that a synchronous override
    /// handles. Retain the returned token for the required observation
    /// lifetime. The token cancels the observation when it is deinitialized.
    /// A delivery that already passed its cancellation check can finish after
    /// cancellation. An observer does not receive events encountered before
    /// its registration.
    ///
    /// - Parameter handler: A callback that receives an owned, sendable event.
    /// - Returns: A token that controls the observation lifetime.
    public func observeOscEvents(
        _ handler: @escaping @Sendable (TerminalOscEvent) -> Void
    ) -> TerminalOscObservation {
        oscEventDispatcher.observe(handler)
    }

    /// Enqueues one copied event before synchronous parser dispatch continues.
    func publishOscEvent(code: Int, payload: ArraySlice<UInt8>) {
        oscEventDispatcher.publish(code: code, payload: payload)
    }
    
    func cmdSet8BitControls ()
    {
        cc.send8bit = true
    }

    func cmdSet7BitControls ()
    {
        cc.send8bit = false
    }

    func emitScroll (_ x: Int)
    {
        // In the original code, it is mediocre accessibility, so likely will remove this
    }
    
    func emitChar (_ ch: Character)
    {
        // In the original code, it is mediocre accessibility, so likely will remove this
    }

    //
    // A partial UTF-8 sequence must remain available for the next feed. The
    // current feed stays in the synchronous print method and is not stored.
    //
    private struct ReadingBuffer: Sendable {
        var putbackBuffer: [UInt8] = []
        
        mutating func reset ()
        {
            putbackBuffer.removeAll (keepingCapacity: true)
        }
    }
    
#if DEBUG
    private var readingBuffer = ReadingBuffer ()
#else
    @exclusivity(unchecked) private var readingBuffer = ReadingBuffer ()
#endif
    
    final func printStateReset ()
    {
        if !readingBuffer.putbackBuffer.isEmpty {
            readingBuffer.reset ()
        }
    }
    
    // TODO: was this unused
    var lastBufferCol: Int = 0

    /// Finds the glyph that owns the terminal cell immediately before the cursor.
    /// A wide glyph has one or more width-zero trailing cells, so walk back to
    /// its leading cell before attempting to extend its grapheme cluster.
    private func combiningTarget(in buffer: Buffer) -> (y: Int, x: Int)?
    {
        let y = buffer.y + buffer.yBase
        var x = buffer.x - 1
        guard x >= 0 else { return nil }

        let line = buffer.lines[y]
        while x > 0 && line.packedWidth(at: x) == 0 {
            x -= 1
        }

        let cell = line.packedView(at: x)
        guard cell.width > 0 && cell.code != 0 else { return nil }
        return (y, x)
    }
    
    final func handlePrint (_ data: ArraySlice<UInt8>)
    {
        let buffer = self.buffer
        var pending = data
        var previousGlyphEndsInZWJ: Bool?

        // Fast path: the leading ASCII run, when there is no charset remapping
        // and no pending partial UTF-8. Only the prefix up to the first high
        // byte goes through the run inserter — an all-or-nothing test would give
        // up the fast path for the whole slice over a single accented letter,
        // which costs about 3x on otherwise-ASCII text.
        if charset == nil && readingBuffer.putbackBuffer.isEmpty {
            let end = ByteRunScanner.firstNonASCIIByte(in: pending, from: pending.startIndex)
            if end > pending.startIndex {
                updateRange(borrowing: buffer, buffer.y)
                let consumed = buffer.insertAsciiRun(pending[pending.startIndex..<end],
                                                     styleID: curStyleID,
                                                     payloadCode: resolveActiveHyperlinkPayloadCode())
                if consumed > 0 {
                    previousGlyphEndsInZWJ = false
                }
                updateRange(borrowing: buffer, buffer.y)
                // A short consume means insertMode is active; the per-character
                // path picks up the rest.
                pending = pending[(pending.startIndex + consumed)...]
                if pending.isEmpty {
                    return
                }
            }
        }

        handlePrintSlow(
            byteCount: pending.count,
            previousGlyphEndsInZWJ: previousGlyphEndsInZWJ
        ) { index in
            pending[pending.startIndex + index]
        }
    }

    /// Processes a borrowed printable run without making an owned batch copy.
    final func handlePrintBorrowed(_ data: Span<UInt8>)
    {
        let buffer = self.buffer
        var pendingStart = 0
        var previousGlyphEndsInZWJ: Bool?

        if charset == nil && readingBuffer.putbackBuffer.isEmpty {
            let end = ByteRunScanner.firstNonASCIIByte(in: data, from: pendingStart)
            if end > pendingStart {
                updateRange(borrowing: buffer, buffer.y)
                let consumed = buffer.insertAsciiRun(
                    data.extracting(pendingStart..<end), styleID: curStyleID,
                    payloadCode: resolveActiveHyperlinkPayloadCode())
                if consumed > 0 {
                    previousGlyphEndsInZWJ = false
                }
                updateRange(borrowing: buffer, buffer.y)
                pendingStart += consumed
                if pendingStart == data.count {
                    return
                }
            }
        }

        handlePrintSlow(
            byteCount: data.count - pendingStart,
            previousGlyphEndsInZWJ: previousGlyphEndsInZWJ
        ) { index in
            data[pendingStart + index]
        }
    }

    /// Processes the non-bulk part of a print run. The byte accessor is
    /// nonescaping, so it can read either an owned slice or a borrowed span.
    private func handlePrintSlow(
        byteCount: Int,
        previousGlyphEndsInZWJ initialPreviousGlyphEndsInZWJ: Bool?,
        byteAt: (Int) -> UInt8
    )
    {
        let buffer = self.buffer
        let putback = readingBuffer.putbackBuffer
        let putbackCount = putback.count
        let totalCount = putbackCount + byteCount
        var inputIndex = 0
        var previousGlyphEndsInZWJ = initialPreviousGlyphEndsInZWJ
        let hyperlinkPayloadCode = resolveActiveHyperlinkPayloadCode()

        @inline(__always)
        func hasNext() -> Bool {
            inputIndex < totalCount
        }

        @inline(__always)
        func bytesLeft() -> Int {
            totalCount - inputIndex
        }

        @inline(__always)
        func getNext() -> UInt8 {
            let result: UInt8
            if inputIndex < putbackCount {
                result = putback[inputIndex]
            } else {
                result = byteAt(inputIndex - putbackCount)
            }
            inputIndex += 1
            return result
        }

        func putBack(_ code: UInt8) {
            var pending = [code]
            pending.reserveCapacity(bytesLeft() + 1)
            while hasNext() {
                pending.append(getNext())
            }
            readingBuffer.putbackBuffer = pending
        }

        updateRange(borrowing: buffer, buffer.y)
        while hasNext() {
            var ch: Character = " "
            var chWidth: Int = 0
            let code = getNext()
            
            let n = UnicodeUtil.expectedSizeFromFirstByte(code)

            if n == -1 || n == 1 {
                // n == -1 means an Invalid UTF-8 sequence, client sent us some junk, happens if we run
                // with the wrong locale set for example if LANG=en, still we handle it here

                // get charset replacement character
                // charset are only defined for ASCII, therefore we only
                // search for an replacement char if code < 127
                if code < 127 && charset != nil {
                    
                    // Notice that the charset mapping can contain the dutch unicode sequence for "ij",
                    // so it is not a simple byte, it is a Character
                    if let str = charset! [UInt8 (code)] {
                        ch = str.first!
                        
                        // Every single mapping in the charset only takes one slot
                        chWidth = 1
                        buffer.insertCharacter(makePackedCell(styleID: curStyleID,
                                                              character: ch,
                                                              width: Int8(chWidth),
                                                              payloadCode: hyperlinkPayloadCode))
                        previousGlyphEndsInZWJ = ch.unicodeScalars.last?.value == 0x200D
                        continue
                    }
                }
                
                let rune = UnicodeScalar (code)
                chWidth = UnicodeUtil.columnWidth(rune: rune)
                if chWidth > 0 {
                    buffer.insertCharacter(makePackedCell(styleID: curStyleID,
                                                          scalar: rune,
                                                          width: Int8(chWidth),
                                                          payloadCode: hyperlinkPayloadCode))
                    previousGlyphEndsInZWJ = false
                }
                continue
            } else if bytesLeft() >= (n-1) {
                // Decode the sequence in place; a temporary [UInt8] fed to
                // UTF8.decode costs a heap allocation per character. On
                // malformed input all n expected bytes stay consumed, even
                // when the offending byte could start a new sequence — the
                // same policy as the UTF8.decode call this replaces.
                var value = UInt32(code) & (0x7F >> UInt32(n))
                var wellFormed = true
                for _ in 1..<n {
                    let byte = getNext()
                    if byte & 0xC0 != 0x80 {
                        wellFormed = false
                    }
                    value = (value << 6) | (UInt32(byte) & 0x3F)
                }
                // Unicode.Scalar.init rejects surrogates and values above
                // 0x10FFFF; the minimum rejects overlong encodings.
                let minimum: UInt32 = n == 2 ? 0x80 : (n == 3 ? 0x800 : 0x10000)
                if wellFormed, value >= minimum, let scalar = Unicode.Scalar(value) {
                    ch = Character(scalar)
                } else {
                    // Invalid UTF-8 sequence, fall back to interpreting the first byte
                    let rune = UnicodeScalar(code)
                    chWidth = UnicodeUtil.columnWidth(rune: rune)
                    if chWidth > 0 {
                        buffer.insertCharacter(makePackedCell(styleID: curStyleID,
                                                              scalar: rune,
                                                              width: Int8(chWidth),
                                                              payloadCode: hyperlinkPayloadCode))
                        previousGlyphEndsInZWJ = false
                    }
                    continue
                }

                // Now the challenge is that we have a character, not a rune, and we want to compute
                // the width of it.
                if ch.unicodeScalars.count == 1 {
                    chWidth = UnicodeUtil.columnWidth(rune: ch.unicodeScalars.first!)
                } else {
                    chWidth = 0
                    for scalar in ch.unicodeScalars {
                        let width = UnicodeUtil.columnWidth(rune: scalar)
                        if width < 0 {
                            chWidth = -1
                            break
                        }
                        chWidth = max (chWidth, width)
                    }
                }
            } else {
                putBack(code)
                return
            }

            if chWidth < 0 {
                continue
            }

            // When regionalIndicatorWidth is .narrow, override individual RI width to 1.
            // The combining logic below will widen the pair to 2 when they form a flag.
            let narrowRI = options.regionalIndicatorWidth == .narrow
            if narrowRI, chWidth == 2,
               let firstScalarForRI = ch.unicodeScalars.first,
               UnicodeUtil.isRegionalIndicator(firstScalarForRI) {
                chWidth = 1
            }

            // Each path that reaches this point starts with one valid multi-byte
            // scalar. ASCII and malformed input continue above, incomplete input
            // returns, and charset mappings continue after inserting their
            // possibly multi-scalar Character. Reuse this scalar when no
            // combination occurs so CellArena does not create a temporary
            // scalar array for an ordinary codepoint.
            //
            // TODO: Retain the scalar produced by the decoder and use it for the
            // width, regional-indicator, combining, and final-insertion checks.
            // Keep charset mappings and a combined newCh on the Character path.
            if let firstScalar = ch.unicodeScalars.first {
                // Check if we should try to combine this character with the previous one.
                // This applies to:
                // 1. Unicode combining characters (diacritics, etc.)
                // 2. Emoji skin tone modifiers (e.g., 🖐 + 🏾 = 🖐🏾)
                // 3. Zero Width Joiner (ZWJ) for emoji sequences (e.g., 👩 + ZWJ + 👩 + ZWJ + 👦 = 👩‍👩‍👦)
                // 4. Variation selectors (e.g., U+FE0F for emoji presentation of ❤️)
                // 5. Any character following a ZWJ (to complete the sequence)
                // All range tests, no stdlib property getters: materializing
                // Unicode.Scalar.Properties allocates a runtime-sized value,
                // whose stack probes would run on every call even when the
                // test itself is skipped. A combining-class test is not
                // needed either: every scalar with a nonzero canonical
                // combining class has column width 0 (enforced by
                // testCombiningScalarsAreZeroWidth), so the chWidth test
                // already covers UnicodeUtil.isCombining(firstScalarValue).
                let firstScalarValue = firstScalar.value
                var shouldTryCombine = chWidth == 0 ||
                                       firstScalarValue == 0x200D ||  // ZWJ
                                       UnicodeUtil.isVariationSelector(firstScalarValue) ||
                                       UnicodeUtil.isEmojiModifier(firstScalarValue)

                // An unknown previous glyph can end in ZWJ. Once this loop
                // knows that it does not, only regional indicators need the
                // preceding glyph to form a pair.
                let needsTarget = shouldTryCombine ||
                                  previousGlyphEndsInZWJ != false ||
                                  UnicodeUtil.isRegionalIndicator(firstScalar)
                let target = needsTarget ? combiningTarget(in: buffer) : nil

                // Also check if the previous character ends with ZWJ - if so, we should combine
                if !shouldTryCombine, let target {
                    let existingLine = buffer.lines[target.y]
                    let lastCell = existingLine.packedView(at: target.x)
                    let lastCode = lastCell.code
                    let lastEndsInZWJ: Bool
                    let lastSingleScalar: Unicode.Scalar?
                    if lastCell.isSimpleRune, lastCode >= 0 {
                        // The code is the cell's single scalar; test it
                        // without materializing a Character.
                        lastSingleScalar = Unicode.Scalar(UInt32(lastCode))
                        lastEndsInZWJ = lastCode == 0x200D
                    } else {
                        let scalars = lastCell.getCharacter().unicodeScalars
                        lastSingleScalar = scalars.count == 1 ? scalars.first : nil
                        lastEndsInZWJ = scalars.last?.value == 0x200D
                    }
                    previousGlyphEndsInZWJ = lastEndsInZWJ
                    if lastEndsInZWJ {
                        shouldTryCombine = true
                    }
                    // Regional indicator combining: pair two RIs into a flag emoji.
                    else if UnicodeUtil.isRegionalIndicator(firstScalar),
                            let lastScalar = lastSingleScalar,
                            UnicodeUtil.isRegionalIndicator(lastScalar) {
                        shouldTryCombine = true
                    }
                }

                if shouldTryCombine, let target {
                    // Fetch the glyph before the cursor, and attempt to combine it.
                    let existingLine = buffer.lines[target.y]
                    let lastx = target.x
                    let cell = existingLine.packedView(at: lastx)

                    // Attempt the combination
                    let newStr = String([cell.getCharacter(), ch])

                    // If the resulting string is 1 grapheme cluster, then it combined properly
                    if newStr.count == 1 {
                        if let newCh = newStr.first {
                            let oldSize = cell.width
                            let isVs16 = firstScalar.value == 0xFE0F
                            let isVs15 = firstScalar.value == 0xFE0E
                            let needsEmojiVariationCheck = isVs16 || isVs15
                            if needsEmojiVariationCheck {
                                let baseScalar = cell.getCharacter().unicodeScalars.last
                                if baseScalar == nil || !UnicodeUtil.isEmojiVs16Base(rune: baseScalar!) {
                                    continue
                                }
                            }
                            if isVs16 {
                                if oldSize != 2 && lastx + 1 < cols {
                                    let updated = cellArena.replacingContent(
                                        of: cell.packed, with: newCh, widthState: .wide)!
                                    existingLine.setPackedCell(updated, at: lastx)
                                    let nextX = lastx + 1
                                    let empty = cellArena.pack(
                                        attribute: cell.attribute, scalar: 0,
                                        widthState: .spacerTail,
                                        payloadCode: cell.packed.payloadCode,
                                        semanticContentCode: cell.packed.semanticContentCode)!
                                    existingLine.setPackedCell(empty, at: nextX)
                                    buffer.x += 1
                                } else {
                                    let state: PackedCell.WidthState = oldSize == 2 ? .wide : .narrow
                                    let updated = cellArena.replacingContent(
                                        of: cell.packed, with: newCh, widthState: state)!
                                    existingLine.setPackedCell(updated, at: lastx)
                                }
                            } else if isVs15 {
                                let updated = cellArena.replacingContent(
                                    of: cell.packed, with: newCh, widthState: .narrow)!
                                existingLine.setPackedCell(updated, at: lastx)
                                if oldSize == 2 && buffer.x > 0 {
                                    buffer.x -= 1
                                }
                            } else if narrowRI && UnicodeUtil.isRegionalIndicator(firstScalar) && oldSize == 1 && lastx + 1 < cols {
                                // In narrow mode, two width-1 RIs combine into a width-2 flag.
                                let updated = cellArena.replacingContent(
                                    of: cell.packed, with: newCh, widthState: .wide)!
                                existingLine.setPackedCell(updated, at: lastx)
                                let empty = cellArena.pack(
                                    attribute: cell.attribute, scalar: 0,
                                    widthState: .spacerTail,
                                    payloadCode: cell.packed.payloadCode,
                                    semanticContentCode: cell.packed.semanticContentCode)!
                                existingLine.setPackedCell(empty, at: lastx + 1)
                                buffer.x += 1
                            } else {
                                let state: PackedCell.WidthState = oldSize == 2 ? .wide : .narrow
                                let updated = cellArena.replacingContent(
                                    of: cell.packed, with: newCh, widthState: state)!
                                existingLine.setPackedCell(updated, at: lastx)
                            }
                            previousGlyphEndsInZWJ = newCh.unicodeScalars.last?.value == 0x200D
                            updateRange(borrowing: buffer, target.y)
                            continue
                        }
                    }
                }
                if chWidth == 0 {
                    continue
                }
                // The accessibility stack might not need this
                //let screenReaderMode = options.screenReaderMode
                //if screenReaderMode {
                //    emitChar (ch)
                //}
                buffer.insertCharacter(makePackedCell(styleID: curStyleID,
                                                      scalar: firstScalar,
                                                      width: Int8(chWidth),
                                                      payloadCode: hyperlinkPayloadCode))
                previousGlyphEndsInZWJ = false
            }
        }
        updateRange(borrowing: buffer, buffer.y)
        readingBuffer.putbackBuffer.removeAll(keepingCapacity: true)
    }

    public func getCharacter (for charData: CharData) -> Character
    {
        charData.getCharacter()
    }

    public func makeCharData (attribute: Attribute, code: Int32, size: Int8 = 1) -> CharData
    {
        return CharData (attribute: attribute, code: code, size: size)
    }

    @inline(__always)
    private func makePackedCell(styleID: UInt16, scalar: UnicodeScalar,
                                width: Int8, payloadCode: UInt16 = 0) -> PackedCell
    {
        let widthState: PackedCell.WidthState = width == 2 ? .wide :
            (width == 0 ? .spacerTail : .narrow)
        guard let cell = cellArena.pack(styleID: styleID, scalar: scalar.value,
                                        widthState: widthState,
                                        payloadCode: payloadCode) else {
            preconditionFailure("The terminal cell arena is full")
        }
        return cell
    }

    @inline(__always)
    private func makePackedCell(styleID: UInt16, character: Character,
                                width: Int8, payloadCode: UInt16 = 0) -> PackedCell
    {
        let widthState: PackedCell.WidthState = width == 2 ? .wide :
            (width == 0 ? .spacerTail : .narrow)
        guard let cell = cellArena.pack(styleID: styleID, character: character,
                                        widthState: widthState,
                                        payloadCode: payloadCode) else {
            preconditionFailure("The terminal cell arena is full")
        }
        return cell
    }

    @inline(__always)
    private func makePackedCell(attribute: Attribute, scalar: UnicodeScalar,
                                width: Int8) -> PackedCell
    {
        let styleID = cellArena.intern(attribute: attribute) ?? 0
        return makePackedCell(styleID: styleID, scalar: scalar, width: width)
    }

    @inline(__always)
    private func makePackedCell(attribute: Attribute, character: Character,
                                width: Int8) -> PackedCell
    {
        let styleID = cellArena.intern(attribute: attribute) ?? 0
        return makePackedCell(styleID: styleID, character: character, width: width)
    }

    public func makeCharData (attribute: Attribute, char: Character, size: Int8 = 1) -> CharData
    {
        var result = CharData(attribute: attribute, code: 0, size: size)
        result.setCharacter(char, size: Int32(size))
        return result
    }

    public func makeCharData (attribute: Attribute, scalar: UnicodeScalar, size: Int8 = 1) -> CharData
    {
        return makeCharData (attribute: attribute, code: Int32 (scalar.value), size: size)
    }

    public func updateCharData (_ charData: inout CharData, char: Character, size: Int32)
    {
        charData.setCharacter(char, size: size)
    }

    public func updateCharData (_ charData: inout CharData, code: Int32, size: Int32)
    {
        charData.setValue (code: code, size: size)
    }
    
//    func insertCharacter2(_ charData: CharData) {
//        let buffer = self.buffer
//        var chWidth = Int (charData.width)
//
//        let right = marginMode ? buffer.marginRight : cols - 1
//        // goto next line if ch would overflow
//        // TODO: needs a global min terminal width of 2
//        // FIXME: additionally ensure chWidth fits into a line
//        //   -->  maybe forbid cols<xy at higher level as it would
//        //        introduce a bad runtime penalty here
//        if buffer.x + chWidth - 1 > right {
//            // autowrap - DECAWM
//            // automatically wraps to the beginning of the next line
//            if wraparound {
//                buffer.x = marginMode ? buffer.marginLeft : 0
//
//                if buffer.y >= buffer.scrollBottom {
//                    scroll (isWrapped: true)
//                } else {
//                    // The line already exists (eg. the initial viewport), mark it as a
//                    // wrapped line
//                    buffer.y += 1
//                    buffer.lines [buffer.y].isWrapped = true
//                }
//                // row changed, get it again
//            } else {
//                if (chWidth == 2) {
//                    // FIXME: check for xterm behavior
//                    // What to do here? We got a wide char that does not fit into last cell
//                    return
//                }
//                // FIXME: Do we have to set buffer.x to cols - 1, if not wrapping?
//                buffer.x = right
//            }
//        } 
//        let bufferRow = buffer.lines [buffer.y + buffer.yBase]
//
//        var empty = CharData.Null
//        empty.attribute = curAttr
//        // insert mode: move characters to right
//        if insertMode {
//            // right shift cells according to the width
//            bufferRow.insertCells (pos: buffer.x, n: chWidth, rightMargin: marginMode ? buffer.marginRight : cols-1, fillData: empty)
//            // test last cell - since the last cell has only room for
//            // a halfwidth char any fullwidth shifted there is lost
//            // and will be set to eraseChar
//            let lastCell = bufferRow [cols - 1]
//            if lastCell.width == 2 {
//                bufferRow [cols - 1] = empty
//            }
//        }
//
//        // write current char to buffer and advance cursor
//        if buffer.x >= cols {
//            buffer.x = cols-1
//        }
//        bufferRow [buffer.x] = charData
//        buffer.x += 1
//
//        // fullwidth char - also set next cell to placeholder stub and advance cursor
//        // for graphemes bigger than fullwidth we can simply loop to zero
//        // we already made sure above, that buffer.x + chWidth will not overflow right
//        if chWidth > 0 {
//            chWidth -= 1
//            while chWidth != 0 && buffer.x < buffer.cols {
//                bufferRow [buffer.x] = empty
//                buffer.x += 1
//                chWidth -= 1
//            }
//        }
//    }

    func cmdLineFeed ()
    {
        cmdLineFeedBasic ()
    }
    
    func cmdLineFeedBasic ()
    {
        let buffer = self.buffer
        let by = buffer.y
        var movedToNextLine = false
        
        let canScroll = !marginMode || (buffer.x >= buffer.marginLeft && buffer.x <= buffer.marginRight)
        if by == buffer.scrollBottom {
            if canScroll {
                scroll(isWrapped: false)
                movedToNextLine = true
            }
        } else if by == rows - 1 {
        } else {
            buffer.y = by + 1
            movedToNextLine = true
            let line = buffer.lines[buffer.yBase + buffer.y]
            if !line.isWrapped {
                line.bidiState = currentBidiState
            }
        }
        
        // If the end of the line is hit, prevent this action from wrapping around to the next line.
        if buffer.x >= cols {
            buffer.x -= 1
        }

        finishSemanticLineAdvance(movedToNextLine: movedToNextLine)
        
        // This event is emitted whenever the terminal outputs a LF or NL.
        emitLineFeed()
        if lineFeedMode {
            buffer.x = usingMargins() ? buffer.marginLeft : 0
        }
    }

    /// The only writer of the continuation epoch (R1). It runs after
    /// `scroll()` has resolved which line object the cursor landed on, so the
    /// push, splice, and recycle scroll branches cannot disagree; the epoch
    /// then travels with the line object.
    ///
    /// Stamping is gated on the interaction state (A.2): it stamps the active
    /// group's ID only while a prompt or its input is being written, never
    /// after submission. The user's submission (R4) normally precedes the
    /// pty's echoed CRLF, so echoed-Enter and pre-`C` output rows (PS0, DEBUG
    /// traps) land in the `.submitted` state and are never stamped.
    private func finishSemanticLineAdvance(movedToNextLine: Bool) {
        guard movedToNextLine else { return }
        let row = buffer.yBase + buffer.y
        guard row >= 0, row < buffer.lines.count else { return }
        // E.4 / R1: stamp only, never write nil. An LF while submitted must not
        // clear a dead group's epoch (that is a destruction path outside R1's
        // list), so a non-stamping advance leaves the row untouched.
        switch buffer.semanticInput {
        case .prompt, .armed: break
        case .idle, .submitted: return
        }
        let line = buffer.lines[row]
        let active = buffer.activeSemanticGroupID
        if let existing = line.semanticHardContinuationGroup, existing != active {
            // Absorbing a row that a now-dead group stamped: drop its stale
            // prompt/input cell tags so leftover cells cannot inflate the
            // active group's offset walk.
            buffer.clearStaleSemanticCells(on: line)
        }
        line.semanticHardContinuationGroup = active
    }

    /// A narrow backstop: `C`/`D` clears the epoch from the row the cursor
    /// occupies when input ends, for the rare case where the pty's echoed
    /// CRLF preceded the user's submission and the landing row was stamped.
    /// With A.2's armed-gated stamping this is usually a no-op.
    private func clearEchoedEnterContinuationBeforeOutput() {
        let row = buffer.yBase + buffer.y
        guard row >= 0, row < buffer.lines.count else { return }
        buffer.lines[row].semanticHardContinuationGroup = nil
    }

    //
    // Backspace handler (Control-h)
    //
    func cmdBackspace ()
    {
        let buffer = self.buffer
        restrictCursor(!reverseWraparound)
        
        let left = marginMode ? buffer.marginLeft : 0
        let right = marginMode ? buffer.marginRight : buffer.cols-1

        if buffer.x > left {
            buffer.x -= 1
        } else if reverseWraparound {
            if buffer.x <= left {
                if buffer.y > buffer.scrollTop && buffer.y <= buffer.scrollBottom && (buffer.lines [buffer.y + buffer.yBase].isWrapped || marginMode) {
                    if !marginMode {
                        buffer.lines [buffer.y + buffer.yBase].isWrapped = false
                    }
                    
                    buffer.y -= 1
                    buffer.x = right
                // TODO: find actual last cell based on width used
                } else if buffer.y == buffer.scrollTop {
                    buffer.x = right
                    buffer.y = buffer.scrollBottom
                } else if buffer.y > 0 {
                    buffer.x = right
                    buffer.y -= 1
                }
            }
        } else {
            if buffer.x < left && buffer.x > 0 {
                // This compensates for the scenario where backspace is supposed to move one step
                // backwards if the "x" position is behind the left margin.
                // Test BS_MovesLeftWhenLeftOfLeftMargin
                buffer.x -= 1
            } else if buffer.x > left {
                // If we have not reached the limit, we can go back, otherwise stop at the margin
                // Test BS_StopsAtLeftMargin
                buffer.x -= 1
            
            }
        }
    }
    
    func cmdCarriageReturn ()
    {
        let buffer = self.buffer
        if marginMode {
            if buffer.x < buffer.marginLeft {
                buffer.x = 0
            } else {
                buffer.x = buffer.marginLeft
            }
        } else {
            buffer.x = 0
        }
    }
    
    //
    // Horizontal tab (control-i)
    //
    func cmdTab ()
    {
        buffer.x = buffer.nextTabStop (marginMode: marginMode)
    }

    // SO
    // ShiftOut (Control-N) Switch to alternate character set.  This invokes the G1 character set
    func cmdShiftOut ()
    {
        setgLevel (1)
    }
    
    // SI
    // ShiftIn (Control-O) Switch to standard character set.  This invokes the G0 character set
    func cmdShiftIn ()
    {
        setgLevel(0)
    }
    
    // Operating System Commands (OSC)

    // MARK: - OSC 133 semantic prompts
    //
    // Store only what the shell said, derive everything else: the buffer
    // stores shell-authored marks and one hard-continuation bit per line;
    // row classification, click eligibility, and logical offsets are all
    // computed on demand from that stored state.

    /// Returns the OSC 133 semantic role for a cell addressed relative to the
    /// start of the active buffer (including scrollback).
    public func semanticContent(at position: Position) -> SemanticContent? {
        guard position.col >= 0, position.col < cols,
              position.row >= 0, position.row < buffer.lines.count else {
            return nil
        }
        return buffer.lines[position.row].packedView(at: position.col).semanticContent
    }

    /// Returns the shell-authored OSC 133 marks stored on a buffer row.
    public func semanticPromptMarks(at row: Int) -> [SemanticPromptAnchor] {
        buffer.semanticPromptMarks(at: row)
    }

    /// The current buffer-absolute row of a line captured earlier, or nil if
    /// scrollback trimming or recycling has since destroyed it. A deferred
    /// pointer click captures the clicked line's identity **and its
    /// `recycleGeneration`**, and re-resolves here at fire time: identity
    /// alone is insufficient because `CircularList.recycle` keeps the trimmed
    /// object in the array as the new bottom row, so a generation mismatch
    /// means the object was reused for different content and the click is
    /// dropped.
    public func semanticRow(forLineIdentity line: BufferLine,
                            recycleGeneration: UInt64) -> Int? {
        guard line.recycleGeneration == recycleGeneration else { return nil }
        return buffer.absoluteRow(of: line)
    }

    /// The `BufferLine` at a buffer-absolute row, for a view to capture a
    /// click target's identity before deferring.
    public func bufferLine(atRow row: Int) -> BufferLine? {
        guard row >= 0, row < buffer.lines.count else { return nil }
        return buffer.lines[row]
    }

    /// Returns the derived classification of a buffer row: `initial` for a
    /// row carrying a group-opening mark, `continuation` for a row reachable
    /// from one through soft wraps or hard continuations, nil otherwise.
    /// Hosts use this for gutter marks and prompt navigation.
    public func semanticRowKind(at row: Int) -> SemanticPromptKind? {
        buffer.semanticRowKind(at: row)
    }

    /// The primary marker for the active OSC 133 prompt group.
    public var activeSemanticPromptOrigin: Position? {
        buffer.activeSemanticPromptOrigin
    }

    /// Sends user input through the terminal so semantic interaction state and
    /// transport cannot diverge. Hosts should use this path for keyboard,
    /// paste, and programmatic input.
    public func sendUserInput(_ data: ArraySlice<UInt8>) {
        registerUserInput(data)
        tdel?.send(source: self, data: data)
    }

    /// Updates semantic interaction state for input delivered by a view.
    ///
    /// Thread contract: this mutates the incremental scanner state and the
    /// buffer's interaction state, so it must run on the terminal's processing
    /// thread — the same thread that calls `feed`. GUI views send on that
    /// thread; `HeadlessTerminal.send` marshals onto its effective queue
    /// (`dispatchQueue ?? .main`) so this still runs, serialized with `feed`,
    /// for hosts that forward pointer clicks (do not delete that hop as dead
    /// code — it is the submission heuristic that keeps clicks from injecting
    /// into a running program).
    func registerUserInput(_ data: ArraySlice<UInt8>) {
        // A wrong suspension costs one dead click; a wrong arm injects bytes
        // into a child process. Heuristics only ever move toward `submitted`,
        // never toward `armed`; the next OSC 133 `B` re-arms.
        if scanUserInputForSubmission(data), buffer.semanticInput == .armed {
            buffer.semanticInput = .submitted
        }
    }

    // An incremental, byte-at-a-time scanner for submission heuristics. It
    // holds no cross-call buffer: a bracketed paste, or any escape sequence,
    // may split across `sendUserInput` calls and the state simply carries
    // over. A malformed CSI whose "terminator" is the ESC of the next
    // sequence never swallows that ESC — an ESC seen mid-CSI abandons the
    // truncated one and starts a fresh escape.
    private enum SemanticScanState: Sendable {
        case ground
        case escape   // saw ESC
        case csi      // saw ESC [
        case ss3      // saw ESC O (SS3; keypad keys under DECKPAM)
    }
    private var semanticScanState: SemanticScanState = .ground
    private var semanticScanInPaste = false
    // Parameter/intermediate bytes of the CSI in progress, bounded so a
    // pathological run cannot grow it without limit.
    private var semanticScanParams: [UInt8] = []

    private func resetUserInputScanner() {
        semanticScanState = .ground
        semanticScanInPaste = false
        semanticScanParams.removeAll(keepingCapacity: true)
    }

    private func scanUserInputForSubmission(_ data: ArraySlice<UInt8>) -> Bool {
        var submission = false
        for byte in data {
            // A newline is never a valid byte inside an escape/CSI/SS3
            // sequence, so it aborts any in-progress one and, outside a
            // bracketed paste, is a submission. Handling it uniformly here is
            // what makes `ESC` then `Enter` (vi-mode) register instead of
            // being swallowed by a mid-sequence state reset.
            if byte == 0x0d || byte == 0x0a {
                if !semanticScanInPaste { submission = true }
                semanticScanState = .ground
                continue
            }
            switch semanticScanState {
            case .ground:
                if byte == 0x1b {
                    semanticScanState = .escape
                }
            case .escape:
                if byte == 0x5b {           // '['
                    semanticScanState = .csi
                    semanticScanParams.removeAll(keepingCapacity: true)
                } else if byte == 0x4f {    // 'O'
                    semanticScanState = .ss3
                } else if byte == 0x1b {
                    semanticScanState = .escape
                } else {
                    semanticScanState = .ground
                }
            case .csi:
                if (0x20...0x3f).contains(byte) {   // parameter and intermediate bytes
                    if semanticScanParams.count < 32 {
                        semanticScanParams.append(byte)
                    }
                    continue
                }
                if (0x40...0x7e).contains(byte) {   // final byte
                    if interpretSemanticCSI(final: byte) {
                        submission = true
                    }
                    semanticScanState = .ground
                } else if byte == 0x1b {
                    // Not a terminator: a new escape sequence begins here.
                    semanticScanState = .escape
                } else {
                    semanticScanState = .ground
                }
            case .ss3:
                // ESC O M is the keypad Enter under DECKPAM, which carries no
                // raw CR byte. Treat it as a submission (the safe side).
                if byte == 0x4d {   // 'M'
                    submission = true
                }
                semanticScanState = .ground
            }
        }
        return submission
    }

    /// Interprets a completed CSI while scanning outgoing input. Returns true
    /// when the sequence is a submission (the kitty Enter key report).
    private func interpretSemanticCSI(final: UInt8) -> Bool {
        let parameters = String(decoding: semanticScanParams, as: UTF8.self)
        switch final {
        case 0x7e: // '~' — bracketed paste markers
            if parameters == "200" {
                semanticScanInPaste = true
            } else if parameters == "201" {
                semanticScanInPaste = false
            }
            return false
        case 0x75: // 'u' — kitty keyboard protocol key report
            let fields = parameters.split(separator: ";", omittingEmptySubsequences: false)
            let keyCode = fields.first?.split(separator: ":", omittingEmptySubsequences: false).first
            guard keyCode == "13" else { return false }
            let modifierParts = fields.count > 1
                ? fields[1].split(separator: ":", omittingEmptySubsequences: false)
                : []
            let isRelease = modifierParts.count > 1 && modifierParts[1] == "3"
            return !isRelease
        default:
            return false
        }
    }

    /// R4: an alternate-screen switch, in either direction, ends the input
    /// region on both buffers and stops `.input` tagging on both.
    private func semanticNoteAlternateScreenSwitch() {
        for screenBuffer in [normalBuffer, altBuffer] {
            screenBuffer.semanticInput = .submitted
            // F.2b: reset both `.input` and `.prompt`, so a prompt hook that
            // launches a full-screen tool between `A` and `B` does not leave the
            // tool's output tagged as prompt.
            switch screenBuffer.semanticContent {
            case .input, .prompt:
                screenBuffer.semanticContent = .output
            case .none, .output:
                break
            }
        }
    }

    /// RIS / DECSTR return both buffers to `idle` and drop the semantic
    /// prompt state; DECSTR additionally clears the marks on the screen rows
    /// (a full reset is one of the three mark-destruction causes).
    private func resetSemanticPromptState(clearingScreenMarks: Bool) {
        for screenBuffer in [normalBuffer, altBuffer] {
            screenBuffer.semanticInput = .idle
            screenBuffer.semanticContent = .none
            screenBuffer.semanticClickMode = .none
            screenBuffer.semanticUsesSpecialCursorKeys = false
            screenBuffer.clearSemanticPromptGroup()
            if clearingScreenMarks {
                let top = screenBuffer.yBase
                let bottom = min(screenBuffer.yBase + rows, screenBuffer.lines.count)
                for row in top..<bottom {
                    screenBuffer.lines[row].destroySemanticState()
                }
            }
        }
        resetUserInputScanner()
    }

    private func semanticPromptModifiersAllow(_ modifiers: SemanticPromptClickModifiers) -> Bool {
        switch semanticPromptClickBehavior {
        case .disabled:
            return false
        case .enabled:
            // Any modifier the views use for their own gestures keeps the
            // click out of the semantic route under the default policy.
            return modifiers.isEmpty
        case .requireModifier(let required):
            return modifiers == required
        }
    }

    // MARK: OSC 133 click translation (R5)

    /// The logical geometry of the active prompt group, built once per click:
    /// the group's rows, and for each row the logical offset at its start,
    /// its logical (hard) line index, and the offset at that line's start.
    private struct SemanticGroupGeometry: Sendable {
        var rows: [Int] = []
        var rowStartOffset: [Int] = []
        var rowLine: [Int] = []
        var rowLineStartOffset: [Int] = []
        var totalOffset = 0
        var hasInput = false
    }

    /// Walks the active group's rows in order: the origin row, then every
    /// row reachable through the `isWrapped` chain or hard continuations.
    /// Soft-wrapped rows join with nothing; each hard boundary counts as one
    /// newline in the offset sequence (consumed by `cl=m`).
    private func semanticGroupGeometry() -> SemanticGroupGeometry? {
        guard let originRow = buffer.semanticPromptStartRow else {
            return nil
        }
        var geometry = SemanticGroupGeometry()
        var offset = 0
        var line = 0
        var lineStart = 0
        var row = originRow
        while true {
            geometry.rows.append(row)
            geometry.rowStartOffset.append(offset)
            geometry.rowLine.append(line)
            geometry.rowLineStartOffset.append(lineStart)
            offset += semanticInputCellCount(in: row, before: cols)
            if offset > geometry.rowStartOffset[geometry.rows.count - 1] {
                geometry.hasInput = true
            }
            let next = row + 1
            guard next < buffer.lines.count else { break }
            let nextLine = buffer.lines[next]
            if nextLine.isWrapped {
                row = next
            } else if buffer.rowContinuesActiveGroupHard(next) {
                // Follow a hard link (epoch or PS2/right group-joining mark) of
                // the active group only, so a dead group's stranded rows never
                // enter the geometry.
                offset += 1
                line += 1
                lineStart = offset
                row = next
            } else {
                break
            }
        }
        geometry.totalOffset = offset
        return geometry
    }

    /// Counts the input cells on a row strictly before `column`. A wide
    /// glyph counts once at its lead column; zero-width cells count zero.
    private func semanticInputCellCount(in row: Int, before column: Int) -> Int {
        let line = buffer.lines[row]
        let limit = min(column, min(cols, line.count))
        var count = 0
        for col in 0..<limit {
            let cell = line.packedView(at: col)
            if cell.semanticContent == .input, cell.width != 0 {
                count += 1
            }
        }
        return count
    }

    /// The logical offset of a position over the group's offset sequence:
    /// the number of input cells (and hard-boundary newlines) strictly
    /// before it. The column is intentionally not clamped to `cols - 1`, so
    /// a pending wrap (`buffer.x == cols`) contributes the full row.
    private func semanticOffset(of position: Position, in geometry: SemanticGroupGeometry)
        -> (offset: Int, line: Int, offsetInLine: Int)? {
        guard let index = geometry.rows.firstIndex(of: position.row) else {
            return nil
        }
        let offset = geometry.rowStartOffset[index]
            + semanticInputCellCount(in: position.row, before: position.col)
        return (offset, geometry.rowLine[index], offset - geometry.rowLineStartOffset[index])
    }

    /// Normalizes a click on a wide glyph's trailing cell to its lead column.
    private func normalizeSemanticClickTarget(_ position: Position) -> Position {
        let line = buffer.lines[position.row]
        guard position.col < line.count else { return position }
        var column = position.col
        while column > 0,
              line.packedWidth(at: column) == 0,
              line.packedView(at: column).semanticContent == .input {
            column -= 1
        }
        return Position(col: column, row: position.row)
    }

    private func appendRepeatedSemanticSequence(_ sequence: [UInt8], count: Int,
                                                to data: inout [UInt8]) {
        guard count > 0 else { return }
        data.reserveCapacity(data.count + sequence.count * count)
        for _ in 0..<count {
            data.append(contentsOf: sequence)
        }
    }

    private func appendSemanticCursorMovement(right: Bool, count: Int, to data: inout [UInt8]) {
        guard count > 0 else { return }
        let sequence: [UInt8]
        if buffer.semanticUsesSpecialCursorKeys {
            // special_key=1 selects the CSI-u encodings the shell asked for.
            sequence = right
                ? [0x1b, 0x5b, 0x31, 0x75]
                : [0x1b, 0x5b, 0x31, 0x3b, 0x31, 0x75]
        } else if right {
            sequence = applicationCursor ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal
        } else {
            sequence = applicationCursor ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal
        }
        appendRepeatedSemanticSequence(sequence, count: count, to: &data)
    }

    private func appendSemanticVerticalMovement(down: Bool, count: Int, to data: inout [UInt8]) {
        guard count > 0 else { return }
        let sequence: [UInt8]
        if down {
            sequence = applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal
        } else {
            sequence = applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal
        }
        appendRepeatedSemanticSequence(sequence, count: count, to: &data)
    }

    /// Every strategy is a pure function of the cursor's and the click's
    /// logical offsets over the same sequence; they differ only in how the
    /// delta is emitted.
    private func semanticCursorMovementData(strategy: SemanticPromptCursorClickMode,
                                            cursor: Position, click: Position,
                                            geometry: SemanticGroupGeometry) -> [UInt8]? {
        guard let cursorInfo = semanticOffset(of: cursor, in: geometry),
              let clickInfo = semanticOffset(of: click, in: geometry) else {
            return nil
        }
        // `cl=line` rejects a click outside the cursor's logical line (not
        // its visual row: soft-wrapped rows are the same line).
        if strategy == .line, cursorInfo.line != clickInfo.line {
            return nil
        }
        let delta = clickInfo.offset - cursorInfo.offset
        if delta == 0 {
            return nil
        }
        var data: [UInt8] = []
        // The shell only defines special forward and backward keys, so with
        // special_key=1 vertical movement is emitted as horizontal steps
        // over the same sequence (hard boundaries cost one step each).
        let crossesLines = cursorInfo.line != clickInfo.line
        if crossesLines, !buffer.semanticUsesSpecialCursorKeys,
           strategy == .conservativeVertical || strategy == .smartVertical {
            appendSemanticCursorMovement(right: false, count: cursorInfo.offsetInLine, to: &data)
            appendSemanticVerticalMovement(down: clickInfo.line > cursorInfo.line,
                                           count: abs(clickInfo.line - cursorInfo.line), to: &data)
            appendSemanticCursorMovement(right: true, count: clickInfo.offsetInLine, to: &data)
        } else {
            appendSemanticCursorMovement(right: delta > 0, count: abs(delta), to: &data)
        }
        return data.isEmpty ? nil : data
    }

    /// R6: the shared arbiter entry point for the views. The snapshot was
    /// captured at press time, before any handler mutated view state; the
    /// click that dismisses a selection, a drag, and multi-clicks are
    /// selection gestures and never reach the semantic route.
    @discardableResult
    public func handleSemanticPromptClick(at position: Position,
                                          modifiers: SemanticPromptClickModifiers,
                                          snapshot: SemanticPromptPointerSnapshot) -> Bool {
        guard snapshot.pressWasSemanticEligible,
              snapshot.clickCount == 1, !snapshot.didDrag, !snapshot.selectionWasActive else {
            return false
        }
        return handleSemanticPromptClick(at: position, modifiers: modifiers)
    }

    /// A cheap pre-check (no geometry, no routing) of whether a completed
    /// primary click could possibly route to the semantic prompt: the press
    /// was semantic-eligible and single, no drag or active selection, the
    /// modifier policy allows it, we are on the normal buffer, the buffer is
    /// armed, and a click mode is set. Views use it to avoid scheduling a
    /// deferral (retaining a line, arming a timer) when routing can never
    /// apply — for example before any OSC 133 has been seen (F.5).
    public func mightRouteSemanticPromptClick(modifiers: SemanticPromptClickModifiers,
                                              snapshot: SemanticPromptPointerSnapshot) -> Bool {
        guard snapshot.pressWasSemanticEligible,
              snapshot.clickCount == 1,
              !snapshot.didDrag,
              !snapshot.selectionWasActive,
              semanticPromptModifiersAllow(modifiers),
              !isCurrentBufferAlternate,
              buffer.semanticInput == .armed,
              buffer.semanticClickMode != .none else {
            return false
        }
        return true
    }

    /// Routes an eligible primary click to the active OSC 133 prompt.
    /// `position` is addressed relative to the start of the active buffer,
    /// matching the positions supplied by the Apple terminal views.
    /// Eligibility is re-derived at click time: the buffer must be armed,
    /// the clicked row must belong to the active group, and the target must
    /// resolve onto input cells.
    ///
    /// Thread contract: call this on the terminal's processing thread — the
    /// same thread that runs `feed` and `registerUserInput` — since it reads
    /// interaction state those paths mutate. Hosts that forward pointer events
    /// from another thread must marshal them onto that thread.
    @discardableResult
    public func handleSemanticPromptClick(at position: Position,
                                          modifiers: SemanticPromptClickModifiers = []) -> Bool {
        guard semanticPromptModifiersAllow(modifiers),
              !isCurrentBufferAlternate,
              buffer.semanticInput == .armed,
              position.col >= 0, position.col < cols,
              position.row >= 0, position.row < buffer.lines.count,
              let geometry = semanticGroupGeometry(),
              geometry.rows.contains(position.row),
              geometry.hasInput else {
            return false
        }

        switch buffer.semanticClickMode {
        case .none:
            return false
        case .clickEventsAbsolute, .clickEventsRelative:
            let x = position.col + 1
            let y: Int
            if buffer.semanticClickMode == .clickEventsRelative {
                guard let relativeOrigin = buffer.semanticPromptRelativeOrigin(for: position),
                      position.row >= relativeOrigin.row else {
                    return false
                }
                y = position.row - relativeOrigin.row
            } else {
                // Absolute rows are reported clamped to the viewport.
                y = min(max(position.row - buffer.yBase + 1, 1), rows)
            }
            sendResponse("\u{1b}[<0;\(x);\(y)M")
            return true
        case .cursorKeys(let strategy):
            // The cursor's offset uses buffer.x unclamped so a pending wrap
            // contributes the full row.
            let cursor = Position(col: buffer.x, row: buffer.yBase + buffer.y)
            guard geometry.rows.contains(cursor.row) else { return false }
            let target = normalizeSemanticClickTarget(position)
            guard let data = semanticCursorMovementData(strategy: strategy,
                                                        cursor: cursor,
                                                        click: target,
                                                        geometry: geometry) else {
                return false
            }
            // One concatenated write per click.
            sendRepeatedSemanticSequence(data)
            return true
        }
    }

    private func sendRepeatedSemanticSequence(_ data: [UInt8]) {
        tdel?.send(source: self, data: data[...])
    }

    // MARK: OSC 133 stream handling (R2, R4)

    private struct SemanticPromptOptions: Sendable {
        var kind = SemanticPromptKind.initial
        var clickEvents: SemanticPromptClickMode?
        var cursorKeys: SemanticPromptClickMode?
        var specialKeys = false

        var clickMode: SemanticPromptClickMode {
            clickEvents ?? cursorKeys ?? .none
        }
    }

    /// Parses the option fields of an OSC 133 action. Unknown option names
    /// (newer protocol extensions) are skipped; a known option with an
    /// unknown or malformed value poisons the whole sequence (returns nil)
    /// so it is ignored entirely: no cursor movement, no state change.
    private func parseSemanticPromptOptions(_ options: [Substring]) -> SemanticPromptOptions? {
        var result = SemanticPromptOptions()
        for option in options {
            guard let separator = option.firstIndex(of: "=") else { continue }
            let value = option[option.index(after: separator)...]
            switch option[..<separator] {
            case "k":
                switch value {
                case "i": result.kind = .initial
                case "r": result.kind = .right
                case "c": result.kind = .continuation
                case "s": result.kind = .secondary
                default: return nil
                }
            case "cl":
                switch value {
                case "line": result.cursorKeys = .cursorKeys(.line)
                case "m": result.cursorKeys = .cursorKeys(.multiple)
                case "v": result.cursorKeys = .cursorKeys(.conservativeVertical)
                case "w": result.cursorKeys = .cursorKeys(.smartVertical)
                default: return nil
                }
            case "click_events":
                switch value {
                case "0": result.clickEvents = nil
                case "1": result.clickEvents = .clickEventsAbsolute
                case "2": result.clickEvents = .clickEventsRelative
                default: return nil
                }
            case "special_key":
                switch value {
                case "0": result.specialKeys = false
                case "1": result.specialKeys = true
                default: return nil
                }
            default:
                continue
            }
        }
        return result
    }

    /// `A` and `N` perform a fresh-line: CR+LF unless already at the left
    /// margin. `k=r` is exempt and never reaches this.
    private func freshSemanticPromptLine() {
        let left = marginMode ? buffer.marginLeft : 0
        guard buffer.x != left else { return }
        cmdCarriageReturn()
        cmdLineFeedBasic()
    }

    // OSC 133 — semantic prompts. Unknown actions, and options with unknown
    // or malformed values, are ignored entirely.
    func oscSemanticPrompt(_ data: ArraySlice<UInt8>) {
        guard !isCurrentBufferAlternate,
              let text = String(bytes: data, encoding: .utf8),
              !text.isEmpty else { return }
        let fields = text.split(separator: ";", omittingEmptySubsequences: false)
        guard let actionField = fields.first, actionField.count == 1,
              let action = actionField.first else { return }
        guard let options = parseSemanticPromptOptions(Array(fields.dropFirst())) else { return }

        switch action {
        case "A", "N":
            let kind = options.kind
            if kind == .right {
                // R4: `k=r` is mark-only — no fresh-line, no origin change, and
                // no interaction-state transition (disarming clicks and
                // re-tagging echo as `.prompt` was a defect). It joins the
                // current group.
                markCurrentSemanticPrompt(kind: .right)
                return
            }
            freshSemanticPromptLine()
            if kind == .continuation {
                // A continuation prompt joins the current group and stores no
                // mark (continuation is a derived-only kind).
                buffer.semanticContent = .prompt(.continuation)
                buffer.semanticInput = .prompt
                return
            }
            // R2 group allocation. `N` always allocates. `A;k=i` reuses the
            // active group only per the identity reuse rule. `A;k=s` joins an
            // open group and anchors a new one only when none is open.
            let originRow = buffer.yBase + buffer.y
            let allocates: Bool
            if action == "N" {
                allocates = true
            } else if kind == .secondary {
                allocates = !buffer.hasSemanticPromptGroup
            } else {
                allocates = !buffer.canReuseSemanticGroup(atRow: originRow)
            }
            if allocates {
                buffer.beginSemanticPromptGroup(originRow: originRow)
                // F.2a: `freshSemanticPromptLine`'s LF stamped this landing row
                // with the OUTGOING group's epoch before we allocated. Clear it
                // so the new origin row is not later absorbed against its own
                // group's cells (E.4), wiping its prompt/input tags.
                if originRow >= 0, originRow < buffer.lines.count {
                    buffer.lines[originRow].semanticHardContinuationGroup = nil
                }
            }
            // F.2c: a primary prompt (a repaint `A;k=i` reuse, or any fresh
            // allocation) reconfigures the click options; a secondary join
            // (`A;k=s`) carries none and must not wipe the group's config.
            if kind == .initial || allocates {
                buffer.semanticClickMode = options.clickMode
                buffer.semanticUsesSpecialCursorKeys = options.specialKeys
            }
            markCurrentSemanticPrompt(kind: kind)
            buffer.semanticContent = .prompt(kind)
            buffer.semanticInput = .prompt
        case "P":
            // A mark action: it classifies the cells that follow but does not
            // move the cursor. `k=s`/`k=c`/`k=r` join the current group;
            // `k=i` follows the same reuse rule as `A`.
            let kind = options.kind
            if kind == .initial {
                if !buffer.canReuseSemanticGroup(atRow: buffer.yBase + buffer.y) {
                    buffer.beginSemanticPromptGroup(originRow: buffer.yBase + buffer.y)
                }
                // F.2c: options on both the allocate and reuse paths.
                buffer.semanticClickMode = options.clickMode
                buffer.semanticUsesSpecialCursorKeys = options.specialKeys
            }
            markCurrentSemanticPrompt(kind: kind)
            buffer.semanticContent = .prompt(kind)
        case "B", "I":
            buffer.semanticContent = .input
            buffer.semanticInput = .armed
        case "C", "D":
            buffer.semanticContent = .output
            buffer.semanticInput = .submitted
            clearEchoedEnterContinuationBeforeOutput()
        case "L":
            // A fresh-line with no classification change.
            freshSemanticPromptLine()
        default:
            return
        }
    }

    private func markCurrentSemanticPrompt(kind: SemanticPromptKind) {
        // Continuation is a derived row kind (R5); the row will classify as
        // a continuation through the hard-continuation chain, so storing a
        // mark for it is a bug by definition (R7).
        guard kind != .continuation else { return }
        let row = buffer.yBase + buffer.y
        buffer.setSemanticMark(kind: kind, row: row, column: buffer.x)
        refresh(startRow: buffer.y, endRow: buffer.y)
    }

    func resetAllColors ()
    {
        ansiColors = defaultAnsiColors
        tdel?.colorChanged (source: self, idx: nil)
    }
    
    func resetColor (_ number: Int)
    {
        if number > 255 {
            return
        }
        ansiColors [number] = defaultAnsiColors [number]
        tdel?.colorChanged(source: self, idx: number)
    }
    
    func oscResetColor (_ data: ArraySlice<UInt8>)
    {
        if data == [] {
            resetAllColors()
        } else {
            if let param = String (bytes: data, encoding: .ascii) {
                let colors = param.split(separator: ";")
                for color in colors {
                    resetColor (Int (color) ?? 0)
                }
            }
        }
    }
    
    // Implements OSC 7 ; URL which records the current working directory
    func oscSetCurrentDirectory (_ data: ArraySlice<UInt8>)
    {
        if !(tdel?.isProcessTrusted(source: self) ?? false) {
            return
        }
        var s = String (bytes:data, encoding: .utf8)
        if s == nil {
            s = String (bytes:data, encoding: .ascii)
        }
        if let txt = s {
            hostCurrentDirectory = txt
            tdel?.hostCurrentDirectoryUpdated (source: self)
        }
    }
    
    // Implements OSC 6 ; URL which records the current document
    func oscSetCurrentDocument (_ data: ArraySlice<UInt8>)
    {
        if !(tdel?.isProcessTrusted(source: self) ?? false) {
            return
        }
        var s = String (bytes:data, encoding: .utf8)
        if s == nil {
            s = String (bytes:data, encoding: .ascii)
        }
        if let txt = s {
            hostCurrentDocument = txt
            tdel?.hostCurrentDocumentUpdated (source: self)
        }
    }

    private enum ActiveHyperlink {
        case pending(String)
        case resolved(TinyAtom)
        case unavailable
    }

    private var activeHyperlink: ActiveHyperlink? = nil
    private var payloadCodes = Set<UInt16>()

    private func resolveActiveHyperlink() -> TinyAtom? {
        guard let activeHyperlink else {
            return nil
        }

        switch activeHyperlink {
        case .pending(let payload):
            guard let atom = makePayload(value: payload) else {
                self.activeHyperlink = .unavailable
                return nil
            }
            self.activeHyperlink = .resolved(atom)
            return atom
        case .resolved(let atom):
            return atom
        case .unavailable:
            return nil
        }
    }

    @inline(__always)
    private func resolveActiveHyperlinkPayloadCode() -> UInt16 {
        resolveActiveHyperlink()?.code ?? 0
    }

    /// Creates a payload atom whose lifetime is managed by this terminal.
    ///
    /// ``garbageCollectPayload()`` releases the atom after it is no longer present in
    /// either terminal buffer. The terminal also releases its remaining atoms when it
    /// is deinitialized.
    public func makePayload<Value: Sendable>(value: Value) -> TinyAtom? {
        guard let atom = TinyAtom.lookup(value: value) else {
            return nil
        }
        payloadCodes.insert(atom.code)
        return atom
    }

    func oscHyperlink (_ data: ArraySlice<UInt8>)
    {
        if data.count == 1 && data [data.startIndex] == UInt8 (ascii: ";") {
            activeHyperlink = nil
        } else {
            let payload = String(bytes: data, encoding: .ascii) ?? ""
            activeHyperlink = .pending(payload)
        }
    }
    
    // OSC 52 – clipboard access
    //    Write:  ESC ] 52 ; <sel> ; <base64-data> ST
    //    Query:  ESC ] 52 ; <sel> ; ?            ST
    //
    // <sel> is one or more characters from {c, p, q, s, 0-7} that identify
    // the selection/clipboard buffer.  On Apple platforms every selection maps
    // to the system clipboard, so we accept any value.  An empty <sel> is
    // treated as "c" (system clipboard).
    func oscClipboard (_ data: ArraySlice<UInt8>) {
        // Find the semicolon that separates the selection identifier from the payload.
        guard let sepIdx = data.firstIndex(of: UInt8(ascii: ";")) else {
            return
        }

        let selectionSlice = data[data.startIndex..<sepIdx]
        let selectionChars = selectionSlice.isEmpty
            ? "c"
            : (String(bytes: selectionSlice, encoding: .ascii) ?? "c")

        let payload = data[(sepIdx + 1)...]

        if payload.count == 1 && payload[payload.startIndex] == UInt8(ascii: "?") {
            // Read / query – ask the delegate for clipboard contents.
            guard let content = tdel?.clipboardRead(source: self) else {
                return
            }
            let base64 = content.base64EncodedString()
            sendResponse(cc.OSC, "52;\(selectionChars);\(base64)", cc.ST)
        } else {
            // Write – decode the base64 payload and hand it to the delegate.
            let base64 = Data(payload)
            guard let content = Data(base64Encoded: base64) else {
                return
            }
            tdel?.clipboardCopy(source: self, content: content)
        }
    }
    
    // Notifications:
    //    ESC ] 777 ; notify ; [title] ; [body] \a
    func oscNotification(_ data: ArraySlice<UInt8>) {
        guard let text = String(bytes: data, encoding: .utf8) else {
            return
        }
        
        let parts = text.components(separatedBy: ";")
        guard parts.count >= 3,
              parts[0] == "notify" else {
            return
        }
        
        let title = parts[1]
        let body = parts[2...].joined(separator: ";")
        tdel?.notify(source: self, title: title, body: body)
    }

    @discardableResult
    func oscProgressReport(_ data: ArraySlice<UInt8>) -> Bool {
        guard let report = parseProgressReport(data) else {
            return false
        }

        tdel?.progressReport(source: self, report: report)
        return true
    }

    private func parseProgressReport(_ data: ArraySlice<UInt8>) -> ProgressReport? {
        guard let text = String(bytes: data, encoding: .ascii) else {
            return nil
        }

        let parts = text.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "4" else {
            return nil
        }

        let statePart = parts[1]
        guard statePart.count == 1,
              let stateValue = Int(statePart),
              let state = ProgressReportState(rawValue: stateValue) else {
            return nil
        }

        var progress: UInt8?
        if parts.count >= 3, !parts[2].isEmpty {
            guard let rawProgress = Int(parts[2]) else {
                return nil
            }
            let clamped = max(0, min(rawProgress, 100))
            progress = UInt8(clamped)
        } else if state == .set {
            progress = 0
        }

        if state == .remove {
            progress = nil
        }

        return ProgressReport(state: state, progress: progress)
    }

    // OSC 1337 is used by iTerm2 for imgcat and other things:
    //  https://iterm2.com/documentation-images.html
    // ESC ] 1337 ; key = value ^G
    //
    // Options
    // ESC ] 1337 ; File = [arguments] : base-64 encoded file contents ^G
    //
    func osciTerm2 (_ data: ArraySlice<UInt8>) {
        if data.elementsEqual("Capabilities".utf8) {
            guard let featureReport = options.featureReport,
                  featureReport.utf8.allSatisfy({ byte in
                      (byte >= 0x30 && byte <= 0x39) ||
                      (byte >= 0x41 && byte <= 0x5a) ||
                      (byte >= 0x61 && byte <= 0x7a)
                  }) else {
                return
            }
            sendResponse(cc.OSC, "1337;Capabilities=\(featureReport)", cc.ST)
            return
        }

        // Parses the key-value pairs separated by ";"
        func parseKeyValues (_ data: ArraySlice<UInt8>) -> [String:String] {
            var kv: [String:String] = [:]
            var current = data.startIndex
            repeat {
                let next = data [current..<data.endIndex].firstIndex(where: { b in b == UInt8 (ascii: ";")}) ?? data.endIndex
                guard let equalIdx = data [current..<next].firstIndex(where: { b in b == UInt8 (ascii: "=")}) else {
                    break
                }
                guard let key = String (bytes: data[current..<equalIdx], encoding: .utf8) else {
                    break
                }
                guard let value = String (bytes: data[equalIdx+1..<next], encoding: .utf8) else {
                    break
                }
                kv [key] = value
                current = next == data.endIndex ? next : next+1
            } while current < data.endIndex
            return kv
        }
        
        /// Parses the dimension specification ("auto", "N%", "Npx" or "N") and returns the enum value for it
        /// puts some artificial limits, to prevent bloat or attacks
        func parseDimension(_ kv: [String:String], key: String) -> ImageSizeRequest {
            let artificialDimensionSizeLimit = 1024*4
            let artificialColumnLimit = 200
            
            guard let v = kv [key] else {
                return .auto
            }
            if v == "auto" { return .auto }
            if v.hasSuffix ("%") {
                if let n = Int (v.dropLast(1)), n > 0, n <= 100 { return .percent (n) }
                return .auto
            }
            if v.hasSuffix("px") {
                if let n = Int (v.dropLast(2)), n > 0, n < artificialDimensionSizeLimit { return .pixels (n) }
                return .auto
            }
            if let n = Int (v), n > 0, n < artificialColumnLimit { return .cells(n) }
            return .auto
        }
        
        guard let equalIdx = data.firstIndex (where: { b in b == UInt8(ascii: "=") }) else {
            return
        }
        
        guard let key = String(bytes: data[data.startIndex..<equalIdx], encoding: .utf8) else {
            return
        }
        switch key {
        case "File":
            guard let colonIdx = data [equalIdx...].firstIndex(where: { b in b == UInt8 (ascii: ":")}) else {
                return
            }
            let kv = parseKeyValues (data [equalIdx+1..<colonIdx])
            // inline == 1 means to display the image inline, the option == 0 downloads the provided file
            // into the file system.   In that case, we let the
            // user of the library handle this via the iTermContent
            // delegate
            if kv["inline"] != "1" {
                break
            }
            
            guard let imgData = Data(base64Encoded: Data(data [colonIdx+1..<data.endIndex])) else {
                return
            }
            let width = parseDimension (kv, key: "width")
            let height = parseDimension (kv, key: "height")

            tdel?.createImage(source: self, data: imgData, width: width, height: height, preserveAspectRatio: (kv ["preserveAspectRatio"] ?? "1" ) == "1")
            return
        default:
            break
        }
        
        tdel?.iTermContent(source: self, content: data)
    }
    
    // OSC 4
    func oscChangeOrQueryColorIndex (_ data: ArraySlice<UInt8>)
    {
        var parsePos = data.startIndex
        while parsePos <= data.endIndex {
            guard let p = data [parsePos...].firstIndex(of: UInt8 (ascii: ";")) else {
                return
            }
            guard let color = EscapeSequenceParser.parseDecimal(data [parsePos..<p]),
                  color < 256 else {
                return
            }
        
            // If the request is a query, reply with the current color definition
            if p+1 < data.endIndex && data [p+1] == UInt8 (ascii: "?") {
                sendResponse (cc.OSC, "4;\(color);\(ansiColors [color].formatAsXcolor())", cc.ST)
                parsePos = p+2
                if parsePos < data.endIndex && data [parsePos] == UInt8(ascii: ";"){
                    parsePos += 1
                }
                continue
            }
    
            //let str = String (bytes:data, encoding: .ascii) ?? ""
            //print ("Parsing color definition \(str)")

            parsePos = p + 1
        
            let end = data [parsePos...].firstIndex(of: UInt8(ascii: ";")) ?? data.endIndex
            
            if let newColor = Color.parseColor (data [parsePos..<end]) {
                ansiColors [color] = newColor
                tdel?.colorChanged (source: self, idx: color)
            }
            parsePos = end+1
        }
        
        //log ("Attempt to set the text Foreground color \(str)")
    }
    
    func reportColor (oscCode: Int, color: Color) {
        sendResponse(cc.OSC, "\(oscCode);\(color.formatAsXcolor ())", cc.ST)
    }

    private func reportColorScheme () {
        let value = colorScheme == .dark ? 1 : 2
        sendResponse(cc.CSI, "?997;\(value)n")
    }

    /// Updates the palette's light/dark preference and, when `notify` is set, notifies the running application if
    /// it subscribed with `CSI ? 2031 h`. Call this after installing the new colors so an application can immediately
    /// re-query OSC 10/11 and receive the updated foreground and background values.
    ///
    /// Pass `notify: false` to record the preference without announcing it: queries (`CSI ? 996 n`, `DECRQM 2031`)
    /// then answer with the new value right away while the host defers the notification with `notifyColorScheme()`.
    public func updateColorScheme (_ colorScheme: TerminalColorScheme, notify: Bool = true) {
        self.colorScheme = colorScheme
        if notify {
            notifyColorScheme()
        }
    }

    /// Sends the current light/dark preference to the running application if it subscribed with `CSI ? 2031 h`.
    /// Safe to repeat: applications treat the notification as a cue to re-query OSC 10/11, so a second one only
    /// costs a round trip and rescues a query that timed out the first time.
    public func notifyColorScheme () {
        if colorSchemeUpdatesEnabled {
            reportColorScheme()
        }
    }
    
    // This handles both setting the foreground, but spill into background and cursor color
    // if more parameters are provided (ie, sending OSC 10 with #ffffff,#000000,#ff0000
    // sets the foreground to #ffffff, background to #000000 and cursor to ff0000
    //
    // - Parameter startAt: describes which of the colors is the first to try,
    // startAt = 0 is foreground, startAt = 1 is background, startAt = 2 is
    // the cursor Color
    func oscSetColors (_ data: ArraySlice<UInt8>, startAt: Int)
    {
        let groups = data.split(separator: UInt8 (ascii: ";"))
        guard !groups.isEmpty else {
            return
        }
        let reportedColors = tdel?.getColors(source: self)
        let queryForeground = reportedColors?.foreground ?? foregroundColor
        let queryBackground = reportedColors?.background ?? backgroundColor
        for (offset, text) in groups.enumerated() {
            let target = startAt + offset
            
            if text.first == UInt8 (ascii: "?") {
                switch target {
                case 0:
                    reportColor (oscCode: 10, color: queryForeground)
                case 1:
                    reportColor (oscCode: 11, color: queryBackground)
                case 2:
                    reportColor (oscCode: 12, color: cursorColor ?? queryForeground)
                default:
                    break
                }
                
                continue
            }

            guard let color = Color.parseColor(text) else {
                continue
            }
            switch target {
            case 0:
                foregroundColor = color
                tdel?.setForegroundColor(source: self, color: color)
            case 1:
                backgroundColor = color
                tdel?.setBackgroundColor(source: self, color: color)
            case 2:
                cursorColor = color
                tdel?.setCursorColor(source: self, color: color)
                break
            default:
                break
            }
        }
    }

    func oscSetTextBackground (_ data: ArraySlice<UInt8>)
    {
        if data.first == UInt8 (ascii: "?") {
            let reportedColors = tdel?.getColors(source: self)
            let queryBackground = reportedColors?.background ?? backgroundColor
            reportColor (oscCode: 11, color: queryBackground)
            return
        }

        if let background = Color.parseColor(data) {
            backgroundColor = background
            tdel?.setBackgroundColor(source: self, color: background)
        }
    }

    func oscSetCursorColor (_ data: ArraySlice<UInt8>)
    {
        if let cursorColor = Color.parseColor(data) {
            self.cursorColor = cursorColor
            tdel?.setCursorColor(source: self, color: cursorColor)
        }
    }

    //
    // ESC E
    // C1.NEL
    //   DEC mnemonic: NEL (https://vt100.net/docs/vt510-rm/NEL)
    //   Moves cursor to first position on next line.
    //
    func cmdNextLine ()
    {
        buffer.x = usingMargins () ? buffer.marginLeft : 0
        cmdIndex ()
    }

    /**
     * ESC H
     * C1.HTS
     *   DEC mnemonic: HTS (https://vt100.net/docs/vt510-rm/HTS.html)
     *   Sets a horizontal tab stop at the column position indicated by
     *   the value of the active column when the terminal receives an HTS.
     *
     * @vt: #Y   C1    HTS   "Horizontal Tabulation Set" "\x88"    "Places a tab stop at the current cursor position."
     * @vt: #Y   ESC   HTS   "Horizontal Tabulation Set" "ESC H"   "Places a tab stop at the current cursor position."
     */
    func cmdTabSet ()
    {
        buffer.tabSet (pos: buffer.x)
    }
    
    //
    // CSI Ps @
    // Insert Ps (Blank) Character(s) (default = 1) (ICH).
    //
    func cmdInsertChars (_ pars: [Int], _ collect: cstring)
    {
        // Do nothing if we are outside the margin
        if marginMode && (buffer.x < buffer.marginLeft || buffer.x > buffer.marginRight) {
            return
        }
        let buffer = self.buffer
        
        buffer.lines[buffer.y + buffer.yBase].insertPackedCells(
            pos: buffer.x, n: pars.count > 0 ? max(pars[0], 1) : 1,
            rightMargin: marginMode ? buffer.marginRight : cols - 1,
            fill: currentEraseBlankCell)

        updateRange (buffer.y)
    }
    
    //
    // CSI Ps A
    // Cursor Up Ps Times (default = 1) (CUU).
    //
    func cmdCursorUp (_ pars: [Int], _ collect: cstring)
    {
        let param = max (pars.count > 0 ? pars [0] : 1, 1)
        let buffer = self.buffer
        var top = buffer.scrollTop
        
        if buffer.y < top {
            top = 0
        }
        if (buffer.y - param < top) {
            buffer.y = top
        } else {
            buffer.y -= param
        }
    }
    
    //
    // CSI Ps B
    // Cursor Down Ps Times (default = 1) (CUD).
    //
    func cmdCursorDown (_ pars: [Int], _ collect: cstring)
    {
        let buffer = self.buffer
        let param = max (pars.count > 0 ? pars [0] : 1, 1)
        
        var bottom = buffer.scrollBottom
        // When the cursor starts below the scroll region, CUD moves it down to the
        // bottom of the screen.
        if buffer.y > bottom {
            bottom = buffer.rows-1
        }
        let newY = buffer.y + param

        if newY >= bottom {
                buffer.y = bottom
        } else {
                buffer.y = newY
        }
        // If the end of the line is hit, prevent this action from wrapping around to the next line.
        if buffer.x >= cols {
                buffer.x -= 1
        }
    }
    
    //
    // CSI Ps B
    // Cursor Forward Ps Times (default = 1) (CUF).
    //
    func cmdCursorForward (_ pars: [Int], _ collect: cstring)
    {
        cursorForward(count: pars.count > 0 ? pars [0] : 1)
    }
    
    func cursorForward (count: Int)
    {
        var right = marginMode ? buffer.marginRight : cols-1
        
        // When the cursor starts after the right margin, CUF moves to the full width
        if buffer.x > right {
            right = buffer.cols - 1
        }
        buffer.x += (max (count, 1))
        if buffer.x > right {
            buffer.x = right
        }
    }

    //
    // CSI Ps D
    // Cursor Backward Ps Times (default = 1) (CUB).
    //
    func cmdCursorBackward (_ pars: [Int], _ collect: cstring)
    {
        cursorBackward(count: pars.count > 0 ? pars [0] : 1)
    }
    
    func cursorBackward (count: Int)
    {
        let buffer = self.buffer
        
        // What is our left margin - depending on the settings.
        var left = marginMode ? buffer.marginLeft : 0
        
        // If the cursor is positioned before the margin, we can go backwards to the first column
        if buffer.x < left {
            left = 0
        }
        let newX = buffer.x - max (1, count)
        if newX < left {
            buffer.x = left
        } else {
            buffer.x = newX
        }
    }

    //
    // CSI Ps I
    //   Cursor Forward Tabulation Ps tab stops (default = 1) (CHT).
    //
    func cmdCursorForwardTab (_ pars: [Int], _ collect: cstring)
    {
        let param = min (cols-1, max (pars.count > 0 ? pars [0] : 1, 1))
        for _ in 0..<param {
            buffer.x = buffer.nextTabStop (marginMode: marginMode)
        }
    }
    
    /**
     * Restrict cursor to viewport size / scroll margin (origin mode)
     * - Parameter limitCols: by default it is true, but the reverseWraparound mechanism in Backspace needs `x` to go beyond.
     */
    func restrictCursor(_ limitCols: Bool = true)
    {
        let buffer = self.buffer
        buffer.x = min (cols - (limitCols ? 1 : 0), max (0, buffer.x))
        buffer.y = originMode
            ? min (buffer.scrollBottom, max (buffer.scrollTop, buffer.y))
            : min (rows - 1, max (0, buffer.y))

        updateRange(borrowing: buffer, buffer.y)
    }

    //
    // CSI Ps ; Ps H
    // Cursor Position [row;column] (default = [1,1]) (CUP).
    //
    func cmdCursorPosition (_ pars: [Int], _ collect: cstring)
    {
        setCursor (col: pars.count >= 2 ? (max (1, pars [1])-1) : 0, row: pars.count >= 1 ? (max (1, pars [0]) - 1) : 0)
    }
    
    func setCursor (col: Int, row: Int)
    {
        let buffer = self.buffer
        updateRange(borrowing: buffer, buffer.y)
        if originMode {
            buffer.x = col + (usingMargins () ? buffer.marginLeft : 0)
            buffer.y = buffer.scrollTop + row
        } else {
            buffer.x = col
            buffer.y = row
        }
        restrictCursor ()
    }

    //
    // CSI Ps E
    // Cursor Next Line Ps Times (default = 1) (CNL).
    // same as CSI Ps B?
    //
    func cmdCursorNextLine (_ pars: [Int], _ collect: cstring)
    {
        cmdCursorDown(pars, collect)
        buffer.x = buffer.marginLeft

        //return
        //let buffer = self.buffer
        //let param = max (pars.count > 0 ? pars [0] : 1, 1)
        //
        //var bottom = buffer.scrollBottom
        //// When the cursor starts below the scroll region, CUD moves it down to the
        //// bottom of the screen.
        //if buffer.y > bottom {
        //    bottom = buffer.rows-1
        //}
        //let newY = buffer.y + param
        //
        //if newY >= bottom {
        //        buffer.y = bottom
        //} else {
        //        buffer.y = newY
        //}
        //// If the end of the line is hit, prevent this action from wrapping around to the next line.
        //if buffer.x >= cols {
        //        buffer.x -= 1
        //}
        //buffer.x = buffer.marginLeft
    }

    //
    // CSI Ps F
    // Cursor Preceding Line Ps Times (default = 1) (CPL).
    // reuse CSI Ps A ?
    //
    func cmdCursorPrecedingLine (_ pars: [Int], _ collect: cstring)
    {
        cmdCursorUp(pars, collect)
        buffer.x = buffer.marginLeft
        
        //let param = max (pars.count > 0 ? pars [0] : 1, 1)
        //let buffer = self.buffer
        //var top = buffer.scrollTop
        //
        //if buffer.y < top {
        //    top = 0
        //}
        //if (buffer.y - param < top) {
        //    buffer.y = top
        //} else {
        //    buffer.y -= param
        //}
        //buffer.x = buffer.marginLeft
    }

    //
    // CSI Ps G
    // Cursor Character Absolute  [column] (default = [row,1]) (CHA).
    //
    func cmdCursorCharAbsolute (_ pars: [Int], _ collect: cstring)
    {
        let buffer = self.buffer
        let param = max (pars.count > 0 ? pars [0] : 1, 1)

        buffer.x = (usingMargins() ? buffer.marginLeft : 0) + min (param - 1, cols - 1)
    }

    //
    // CSI Ps K  Erase in Line (EL).
    //     Ps = 0  -> Erase to Right (default).
    //     Ps = 1  -> Erase to Left.
    //     Ps = 2  -> Erase All.
    // CSI ? Ps K
    //   Erase in Line (DECSEL).
    //     Ps = 0  -> Selective Erase to Right (default).
    //     Ps = 1  -> Selective Erase to Left.
    //     Ps = 2  -> Selective Erase All.
    //
    func cmdEraseInLine (_ pars: [Int], _ collect: cstring)
    {
        let p = pars.count == 0 ? 0 : pars [0]
        
        switch p {
        case 0:
            eraseInBufferLine (y: buffer.y, start: buffer.x, end: cols)
        case 1:
            eraseInBufferLine (y: buffer.y, start: 0, end: buffer.x + 1)
        case 2:
            eraseInBufferLine (y: buffer.y, start: 0, end: cols)
        default:
            break
        }
        updateRange (buffer.y)
    }

    //
    // CSI Ps J  Erase in Display (ED).
    //     Ps = 0  -> Erase Below (default).
    //     Ps = 1  -> Erase Above.
    //     Ps = 2  -> Erase All.
    //     Ps = 3  -> Erase Saved Lines (xterm).
    // CSI ? Ps J
    //   Erase in Display (DECSED).
    //     Ps = 0  -> Selective Erase Below (default).
    //     Ps = 1  -> Selective Erase Above.
    //     Ps = 2  -> Selective Erase All.
    //
    func cmdEraseInDisplay (_ pars: [Int], _ collect: cstring)
    {
        let p = pars.count == 0 ? 0 : pars [0]
        var j: Int
        switch p {
        case 0:
            j = buffer.y
            updateRange (j)
            eraseInBufferLine (y: j, start: buffer.x, end: cols, clearWrap: buffer.x == 0)
            j += 1
            while j < rows {
                resetBufferLine (y: j, bidiState: currentBidiState)
                j += 1
            }
            updateRange (j - 1)
            
        case 1:
            j = buffer.y
            updateRange (j)
            // Deleted front part of line and everything before. This line will no longer be wrapped.
            eraseInBufferLine (y: j, start: 0, end: buffer.x + 1, clearWrap: true)
            if buffer.x + 1 >= cols && j + 1 < rows {
                // Deleted entire previous line. This next line can no longer be wrapped.
                buffer.lines [buffer.yBase + j + 1].isWrapped = false
            }
            while (j != 0) {
                j -= 1
                resetBufferLine (y: j, bidiState: currentBidiState)
            }
            updateRange (0)
        case 2:
            j = rows
            updateRange (j - 1)
            while (j != 0) {
                j -= 1
                resetBufferLine (y: j, clearImages: true, bidiState: currentBidiState)
            }
            clearAllKittyImages()
            updateRange (0)
        case 3:
            // Clear scrollback (everything not in viewport)
            let scrollBackSize = buffer.lines.count - rows
            if scrollBackSize > 0 {
                buffer.lines.trimStart (count: scrollBackSize)
                buffer.linesTop = 0
                buffer.yBase = max (buffer.yBase - scrollBackSize, 0)
                buffer.yDisp = max (buffer.yDisp - scrollBackSize, 0)
            }
            break;
        default:
            break
        }
    }

    //
    // Helper method to erase cells in a terminal row.
    // The cell gets replaced with the eraseChar of the terminal.
    // - Parameter y: row index
    // - Parameter start: first cell index to be erased
    // - Parameter end:   end - 1 is last erased cell
    //
    func eraseInBufferLine (y: Int, start: Int, end: Int, clearWrap: Bool = false, clearRenderMode: Bool = false, clearImages: Bool = false)
    {
        let line = buffer.lines [buffer.yBase + y]
        if clearImages {
            buffer.clearImagesFromLine(at: buffer.yBase + y)
        }
        line.replacePackedCells(start: start, end: end,
                                fill: currentEraseBlankCell)
        if clearWrap {
            line.isWrapped = false
        }
        if clearRenderMode {
            line.renderMode = .single
        }
    }

    //
    // CSI Ps L
    // Insert Ps Line(s) (default = 1) (IL).
    //
    func cmdInsertLines (_ pars: [Int], _ collect: cstring)
    {
        let buffer = self.buffer
        if buffer.y < buffer.scrollTop || buffer.y > buffer.scrollBottom {
            return
        }
        // to prevent a Denial of Service
        let maxLines = buffer.lines.maxLength * 2
        var p = min (maxLines, max (pars.count == 0 ? 1 : pars [0], 1))
        let row = buffer.y + buffer.yBase
        
        let scrollBottomRowsOffset = rows - 1 - buffer.scrollBottom
        let scrollBottomAbsolute = rows - 1 + buffer.yBase - scrollBottomRowsOffset + 1
        
        let eraseBlank = currentEraseBlankCell
        if marginMode {
            if buffer.x >= buffer.marginLeft && buffer.x <= buffer.marginRight {
                let columnCount = buffer.marginRight-buffer.marginLeft+1
                let rowCount = buffer.scrollBottom-buffer.scrollTop
                for _ in 0..<p {
                    for i in (0..<rowCount).reversed() {
                        let src = buffer.lines [row+i]
                        let dst = buffer.lines [row+i+1]
                        
                        dst.copyFrom(src, srcCol: buffer.marginLeft, dstCol: buffer.marginLeft, len: columnCount)
                    }
                    
                    let last = buffer.lines [row]
                    last.fill(with: eraseBlank,
                              atCol: buffer.marginLeft, len: columnCount)
                }

                selectionsInvalidateForColumnRestrictedScroll (top: row, bottom: row + rowCount, left: buffer.marginLeft, right: buffer.marginRight)
            }
        } else {
            let inserted = p
            for _ in 0..<p {
                p -= 1
                // test: echo -e '\e[44m\e[1L\e[0m'
                // blankLine(true) - xterm/linux behavior
                buffer.lines.splice (start: scrollBottomAbsolute - 1, deleteCount: 1, items: [],
                                     change: { line in updateRange (line) })
                let newLine = buffer.getBlankLine(packedBlank: eraseBlank)
                buffer.lines.splice (start: row, deleteCount: 0, items: [newLine], change: { line in updateRange (line) })
            }

            // Rows below the cursor moved down in place.
            selectionsAdjustForInPlaceScroll (top: row, bottom: scrollBottomAbsolute - 1, lines: -inserted)
            let firstMovedRow = row + inserted < scrollBottomAbsolute
                ? row + inserted : nil
            hardenBidiLineShiftBoundaries(firstChangedRow: row,
                                           firstMovedRow: firstMovedRow,
                                           lastChangedRow: scrollBottomAbsolute - 1)
        }
        // this.maxRange();
        updateRange (startLine: buffer.y, endLine: buffer.scrollBottom)
        // A restricted region leaves stale pixels / a bottom-edge ghost outside
        // [y, scrollBottom] on the CG renderer (as in scroll()); the range above
        // already covers full-screen, so widen to the whole viewport only when the
        // region is restricted.
        refreshScrolledRegion(top: buffer.scrollTop, bottom: buffer.scrollBottom, canBlit: true)
    }
    
    //
    // ESC ( C
    //   Designate G0 Character Set, VT100, ISO 2022.
    // ESC ) C
    //   Designate G1 Character Set (ISO 2022, VT100).
    // ESC * C
    //   Designate G2 Character Set (ISO 2022, VT220).
    // ESC + C
    //   Designate G3 Character Set (ISO 2022, VT220).
    // ESC - C
    //   Designate G1 Character Set (VT300).
    // ESC . C
    //   Designate G2 Character Set (VT300).
    // ESC / C
    //   Designate G3 Character Set (VT300). C = A  -> ISO Latin-1 Supplemental. - Supported?
    //
    func selectCharset (_ p: ArraySlice<UInt8>)
    {
        if p.count == 2 {
            // print ("Settin charset to \(p[1])")
        }
        
        if (p.count != 2) {
            cmdSelectDefaultCharset ()
            return
        }
        var ch: UInt8
        var charset: [UInt8:String]?
        
        if let mappedCharset = CharSets.all[p[1]] {
            charset = mappedCharset
        } else {
            charset = nil
        }
        
        switch p [0] {
        case UInt8 (ascii: "("):
            ch = 0
        case UInt8 (ascii: ")"):
            ch = 1
        case UInt8 (ascii: "-"):
            ch = 1
        case UInt8 (ascii: "*"):
            ch = 2
        case UInt8 (ascii: "."):
            ch = 2
        case UInt8 (ascii: "+"):
            ch = 3
        case UInt8 (ascii: "/"):
            ch = 3
        default:
            return;
        }
        setgCharset (ch, charset: charset)
    }

    func setLineRenderMode (to: BufferLine.RenderLineMode) {
        buffer.lines [buffer.y + buffer.yBase].renderMode = to
        updateRange (buffer.y)
    }
    
    //
    // ESC #6
    //
    func cmdDoubleWidthSingleHeight ()
    {
        setLineRenderMode(to: .doubleWidth)
    }
    
    //
    // dhtop
    //
    func cmdSetDoubleHeightTop ()
    {
        setLineRenderMode(to: .doubledTop)
    }
    
    // dhbot
    func cmdSetDoubleHeightBottom ()
    {
        setLineRenderMode(to: .doubledDown)
    }
    
    //
    // swsh
    //
    func cmdSingleWidthSingleHeight ()
    {
        setLineRenderMode(to: .single)
    }
    
    // ESC # 8
    func cmdScreenAlignmentPattern ()
    {
        let cell = makePackedCell(attribute: curAttr.justColor(),
                                  character: "E", width: 1)

        setCursor (col: 0, row: 0)
        for yOffset in 0..<rows {
            let rowN = buffer.y + buffer.yBase + yOffset
            buffer.lines [rowN].fill(with: cell)
            buffer.lines [rowN].isWrapped = false
        }
        updateFullScreen()
        setCursor(col: 0, row: 0)
    }

    func cmdRestoreCursor (_ pars: [Int], _ collect: cstring)
    {
        // CSI u (no intermediates) = DECRC (Restore Cursor)
        // CSI > Ps u / CSI < u / CSI = Ps u = Kitty keyboard protocol (not cursor commands)
        guard collect.isEmpty else { return }

        // Clamp savedX and savedY to valid ranges to prevent abort() in Debug builds.
        // Saved values can become invalid after resize/scroll operations.
        buffer.x = min(max(0, buffer.savedX), cols - 1)
        buffer.y = min(max(0, buffer.savedY), rows - 1)
        setCurrentAttribute(buffer.savedAttr)
        charset = buffer.savedCharset
        originMode = buffer.savedOriginMode
        setMarginMode(buffer.savedMarginMode)
        setWraparound(buffer.savedWraparound)
        reverseWraparound = buffer.savedReverseWraparound
    }

    //
    // Validates optional arguments for top, left, bottom, right sent by various
    // escape sequences and returns validated top, left, bottom, right in our 0-based
    // internal coordinates
    //
    func getRectangleFromRequest (_ pars: ArraySlice<Int>) -> (top: Int, left: Int, bottom: Int, right: Int)?
    {
        let buffer = self.buffer
        let b = pars.startIndex
        var top = max (1, pars.count > 0 ? pars [b] : 1)
        var left = max (pars.count > 1 ? pars [b+1] : 1, 1)
        var bottom = pars.count > 2 ? pars [b+2] : -1
        var right = pars.count > 3 ? pars [b+3] : -1

        if bottom < 0 {
            bottom = rows
        }
        if right < 0 {
            right = cols
        }
        if right > cols {
            right = cols
        }
        if bottom > rows {
            bottom = rows
        }
        if originMode {
            top += buffer.scrollTop
            bottom += buffer.scrollTop
            left += buffer.marginLeft
            right += buffer.marginLeft
        }
        if top > bottom || left > right {
            return nil
        }
        //top = min (top, bottom)
        //left = min (left, right)
        let rowBound = rows-1
        let colBound = cols-1
        return (min (rowBound, top-1), min (colBound, left-1), min (rowBound, bottom-1), min (colBound, right-1))
    }
    
    //
    // Copy Rectangular Area (DECCRA), VT400 and up.
    // CSI Pts ; Pls ; Pbs ; Prs ; Pps ; Ptd ; Pld ; Ppd $ v
    //  Pts ; Pls ; Pbs ; Prs denotes the source rectangle.
    //  Pps denotes the source page.
    //  Ptd ; Pld denotes the target location.
    //  Ppd denotes the target page.
    func csiCopyRectangularArea (_ ipars: [Int], _ collect: cstring)
    {
        if collect.count > 0 && collect == [36] {
            var pars: [Int] = []
            pars.append (ipars.count > 1 && ipars [0] != 0 ? ipars [0] : 1) // Pts default 1
            pars.append (ipars.count > 2 && ipars [1] != 0 ? ipars [1]: 1) // Pls default 1
            pars.append (ipars.count > 3 && ipars [2] != 0 ? ipars [2]: rows-1) // Pbs default to last line of page
            pars.append (ipars.count > 4 && ipars [3] != 0 ? ipars [3]: cols-1) // Prs defaults to last column
            pars.append (ipars.count > 5 && ipars [4] != 0 ? ipars [4]: 1) // Pps page source = 1
            pars.append (ipars.count > 6 && ipars [5] != 0 ? ipars [5]: 1) // Ptd default is 1
            pars.append (ipars.count > 7 && ipars [6] != 0 ? ipars [6]: 1) // Pld default is 1
            pars.append (ipars.count > 8 && ipars [7] != 0 ? ipars [7]: 1) // Ppd default is 1
            
            // We only support copying on the same page, and the page being 1
            if pars [4] == pars [7] && pars [4] == 1 {
                if let (top, left, bottom, right) = getRectangleFromRequest(pars [0...3]) {
                    let rowTarget = min (rows-1, pars [5]-1)
                    let colTarget = min (cols-1, pars [6]-1)
                    
                    // Block size
                    let columns = right - left + 1
                    let copyCount = min(columns, cols - colTarget)
                    guard copyCount > 0 else { return }
                    let sourceRight = left + copyCount - 1
                    
                    var lines: [[PackedCell]] = []
                    for row in top...bottom {
                        let line = buffer.lines [row+buffer.yBase]
                        var lineCopy: [PackedCell] = []
                        for col in left...sourceRight {
                            lineCopy.append(line.packedCell(at: col))
                        }
                        lines.append(lineCopy)
                    }
                    
                    for row in 0...(bottom-top) {
                        if row+rowTarget >= buffer.rows {
                            break
                        }
                        let line = buffer.lines [row+rowTarget+buffer.yBase]
                        let lr = lines [row]
                        for col in lr.indices {
                            if col >= buffer.cols {
                                break
                            }
                            line.setPackedCell(lr[col], at: colTarget + col)
                        }
                    }
                }
            }
        }
    }

    // CSI Ps x  Request Terminal Parameters (DECREQTPARM).
    // CSI Ps * x Select Attribute Change Extent (DECSACE), VT420 and up.
    // CSI Pc ; Pt ; Pl ; Pb ; Pr $ x Fill Rectangular Area (DECFRA), VT420 and up.
    func csiX (_ pars: [Int], _ collect: cstring)
    {
        if collect.count > 0 && collect == [UInt8 (ascii: "$")] {
            // DECFRA
            if let (top, left, bottom, right) = getRectangleFromRequest(pars [1...]) {
                let scalar = UnicodeScalar (pars [0]) ?? UnicodeScalar (32)!
                let fillData = makePackedCell(styleID: curStyleID, scalar: scalar, width: 1)
                for row in top...bottom {
                    let line = buffer.lines [row+buffer.yBase]
                    for col in left...right {
                        line.setPackedCell(fillData, at: col)
                    }
                }
            }
        } else {
            log ("Not implemented CSI x with collect: collect=\(collect) and pars=\(pars)")
        }
    }

    //
    // CSI # }   Pop video attributes from stack (XTPOPSGR), xterm.  Popping
    //           restores the video-attributes which were saved using XTPUSHSGR
    //           to their previous state.
    //
    // CSI Pm ' }
    //           Insert Ps Column(s) (default = 1) (DECIC), VT420 and up.
    //
    func csiCloseBrace (_ pars: [Int], _ collect: cstring)
    {
        if collect.count > 0 && collect == [39 /* ' */] {
             // DECIC - Insert Column
            let n = pars.count > 0 ? max (pars [0],1) : 1
            let buffer = self.buffer
            
            if marginMode && buffer.x < buffer.marginLeft || buffer.x > buffer.marginRight {
                return
            }
            
            for row in buffer.scrollTop...buffer.scrollBottom {
                let line = buffer.lines [row+buffer.yBase]
                line.insertPackedCells(
                    pos: buffer.x, n: n,
                    rightMargin: marginMode ? buffer.marginRight : cols - 1,
                    fill: buffer.getPackedNullCell())
                line.isWrapped = false
            }
            return
        } else {
            log ("CSI # } not implemented- XTPOPSGR with \(pars)")
        }
    }
    
    // Required by the test suite
    // CSI Pi ; Pg ; Pt ; Pl ; Pb ; Pr * y
    // Request Checksum of Rectangular Area (DECRQCRA), VT420 and up.
    // Response is
    // DCS Pi ! ~ x x x x ST
    //   Pi is the request id.
    //   Pg is the page number.
    //   Pt ; Pl ; Pb ; Pr denotes the rectangle.
    //   The x's are hexadecimal digits 0-9 and A-F.
    func cmdDECRQCRA (_ pars: [Int], _ collect: cstring)
    {
        var checksum: UInt32 = 0
        let rid = pars.count > 0 ? pars [0] : 1
        let _ = pars.count > 1 ? pars [1] : 0
        var result = "0000"
        if (tdel?.isProcessTrusted(source: self) ?? false) && pars.count > 2 {
            if let (top, left, bottom, right) = getRectangleFromRequest(pars [2...]) {
                for row in top...bottom {
                    let line = buffer.lines [row+buffer.yBase]
                    for col in left...right {
                        let cell = line.packedView(at: col)
                        let ch = cell.code == 0 ? " " : cell.getCharacter()
                        
                        for scalar in ch.unicodeScalars {
                            checksum += scalar.value
                        }
                    }
                }
            }
            result = String(format: "%04x", checksum)
        }
        sendResponse (cc.DCS, "\(rid)!~\(result)", cc.ST)
    }

    // Dispatcher for CSI .* z commands
    func csiZ (_ pars: [Int], _ collect: cstring)
    {
        switch collect {
        case [UInt8 (ascii: "$")]:
            cmdDECERA (pars)
        case [UInt8 (ascii: "'")]:
            // Enable Locator Reporting (DECELR).
            // Valid values for the first parameter:
            //   Ps = 0  ⇒  Locator disabled (default).
            //   Ps = 1  ⇒  Locator enabled.
            //   Ps = 2  ⇒  Locator enabled for one report, then disabled.
            // The second parameter specifies the coordinate unit for locator
            // reports.
            // Valid values for the second parameter:
            //   Pu = 0  or omitted ⇒  default to character cells.
            //   Pu = 1  ⇐  device physical pixels.
            //   Pu = 2  ⇐  character cells.
            print ("TODO: Enable Locator Reporting (DECELR)")
        default:
            break
        }
    }
    
    // DECERA - Erase Rectangular Area
    // CSI Pt ; Pl ; Pb ; Pr ; $ z
    func cmdDECERA (_ pars: [Int])
    {
        if let (top, left, bottom, right) = getRectangleFromRequest(pars [0...]) {
            let fillData = makePackedCell(styleID: curStyleID, character: " ", width: 1)
            for row in top...bottom {
                let line = buffer.lines [row+buffer.yBase]
                for col in left...right {
                    line.setPackedCell(fillData, at: col)
                }
            }
        }
    }

    // Dispatches to DECSERA or XTPUSHSGR
    func csiOpenBrace (_ pars: [Int], _ collect: cstring)
    {
        if collect.count > 0 && collect == [UInt8 (ascii: "$")] {
            cmdSelectiveEraseRectangularArea (pars)
        } else {
            log ("CSI # { not implemented - XTPUSHSGR with \(pars)")
        }
    }
    
    // Push video attributes onto stack (XTPUSHSGR), xterm.
    func cmdPushSg (_ pars: [Int])
    {
        
    }
    
    // DECSERA - Selective Erase Rectangular Area
    // CSI Pt ; Pl ; Pb ; Pr ; $ {
    func cmdSelectiveEraseRectangularArea (_ pars: [Int])
    {
        if let (top, left, bottom, right) = getRectangleFromRequest(pars [0...]) {
            for row in top...bottom {
                let line = buffer.lines [row+buffer.yBase]
                for col in left...right {
                    let cell = line.packedCell(at: col)
                    guard !cell.isProtected,
                          let erased = cellArena.replacingContent(
                            of: cell, with: " ", widthState: .narrow) else {
                        continue
                    }
                    line.setPackedCell(erased, at: col)
                }
            }
        }
    }
    /**
     * Commands send to the `windowCommand` delegate for the front-end to implement capabilities
     * on behalf of the client.  The expected return strings in some of these enumeration values is documented
     * below.   Returns are only expected for the enum values that start with the prefix `report`
     */
    public enum WindowManipulationCommand: Sendable {
        /// Raised when the backend should deiconify a window, no return expected
        case deiconifyWindow
        /// Raised when the backend should iconify  a window, no return expected
        case iconifyWindow
        /// Raised when the client would like the window to be moved to the x,y position int he screen, not return expected
        case moveWindowTo(x: Int, y: Int)
        /// Raised when the client would like the window to be resized to the specified widht and heigh in pixels, not return expected
        case resizeWindowTo(width: Int, height: Int)
        /// Raised to bring the terminal to the front
        case bringToFront
        /// Send the terminal to the back if possible
        case sendToBack
        /// Trigger a terminal refresh
        case refreshWindow
        /// Request that the size of the terminal be changed to the specified cols and rows
        case resizeTo(cols: Int, rows: Int)
        /// Request that the size of the terminal be changed to the specified cols and rows.
        /// Prefer this over `resizeTo(cols:rows:)` which cannot be disambiguated from
        /// `resizeTo(lines:)` in switch statements due to a Swift compiler limitation.
        case resizeTerminal(cols: Int, rows: Int)
        case restoreMaximizedWindow
        /// Attempt to maximize the window
        case maximizeWindow
        /// Attempt to maximize the window vertically
        case maximizeWindowVertically
        /// Attempt to maximize the window horizontally
        case maximizeWindowHorizontally
        case undoFullScreen
        case switchToFullScreen
        case toggleFullScreen
        case reportTerminalState
        case reportTerminalPosition
        case reportTextAreaPosition
        // CSI 14 t
        case reportTextAreaPixelDimension
        // CSI 14; 2 t
        case reportTerminalWindowPixelDimension
        // CSI 15 t
        case reportSizeOfScreenInPixels
        // CSI 16 t
        case reportCellSizeInPixels
        // CSI 18 t
        case reportTextAreaCharacters
        // CSI 19 t
        case reportScreenSizeCharacters
        case reportIconLabel
        case reportWindowTitle
        case resizeTo (lines: Int)
    }

    // Dispatches to
    func csit (_ pars: [Int], _ collect: cstring)
    {
        switch collect {
        case []:
            cmdWindowOptions(pars)
        case [UInt8 (ascii: ">")]:
            cmdXtermTitleModeSet(pars)
        default:
            log ("Unhandled csiT \(collect)")
        }
    }
    
    func cmdXtermTitleModeSet (_ pars: [Int])
    {
        // Use the windowTextEncoding type
        for par in pars {
            switch par {
            case 0:
                // Set window/icon labels using hexadecimal.
                xtermTitleSetHex = true
                break
            case 1:
                // Query window/icon labels using hexadecimal.
                xtermTitleQueryHex = true
                break
            case 2:
                // Set window/icon labels using UTF-8.
                xtermTitleSetUtf = true
                break
            case 3:
                // Query window/icon labels using UTF-8.
                xtermTitleQueryUtf = true
                break
            default:
                break
            }
        }
    }
    
    func cmdXtermTitleModeReset (_ pars: [Int])
    {
        // Use the windowTextEncoding type
        for par in pars {
            switch par {
            case 0:
                // Do not set window/icon labels using hexadecimal.
                xtermTitleSetHex = false
                break
            case 1:
                // Do not query window/icon labels using hexadecimal
                xtermTitleQueryHex = false
                break
            case 2:
                // Do not set window/icon labels using UTF-8.
                xtermTitleSetUtf = false
                break
            case 3:
                // Do not query window/icon labels using UTF-8.
                xtermTitleQueryUtf = false
                break
            default:
                break
            }
        }
    }

    //
    // CSI Ps ; Ps ; Ps t - Various window manipulations and reports (xterm)
    // See https://invisible-island.net/xterm/ctlseqs/ctlseqs.html for a full
    // list of commans for this escape sequence
    func cmdWindowOptions (_ pars: [Int])
    {
        guard let tdel = self.tdel else {
            return
        }
        switch pars {
        case [1]:
            tdel.windowCommand(source: self, command: .deiconifyWindow)
        case [2]:
            tdel.windowCommand(source: self, command: .iconifyWindow)
        case _ where pars.count == 3 && pars.first == 3:
            tdel.windowCommand(source: self, command: .moveWindowTo(x: pars [1], y: pars[2]))
        case _ where pars.count == 3 && pars.first == 4:
            tdel.windowCommand(source: self, command: .moveWindowTo(x: pars [1], y: pars[2]))
        case [5]:
            tdel.windowCommand(source: self, command: .bringToFront)
        case [6]:
            tdel.windowCommand(source: self, command: .sendToBack)
        case [7]:
            tdel.windowCommand(source: self, command: .refreshWindow)
        case _ where pars.count == 3 && pars.first == 8:
            tdel.windowCommand(source: self, command: .resizeTerminal(cols: pars [1], rows: pars [2]))
        case [9, 0]:
            tdel.windowCommand(source: self, command: .restoreMaximizedWindow)
        case [9, 1]:
            tdel.windowCommand(source: self, command: .maximizeWindow)
        case [9, 2]:
            tdel.windowCommand(source: self, command: .maximizeWindowVertically)
        case [9, 3]:
            tdel.windowCommand(source: self, command: .maximizeWindowHorizontally)
        case [10, 0]:
            tdel.windowCommand(source: self, command: .undoFullScreen)
        case [10, 1]:
            tdel.windowCommand(source: self, command: .switchToFullScreen)
        case [10, 2]:
            tdel.windowCommand(source: self, command: .toggleFullScreen)
        case [14]:
            if let r = tdel.windowCommand(source: self, command: .reportTextAreaPixelDimension) {
                sendResponse(r)
            } else {
                let cellSize = tdel.cellSizeInPixels(source: self) ?? (width: 10, height: 16)
                sendResponse(cc.CSI, "4;\(rows * cellSize.height);\(cols * cellSize.width)t")
            }
        case [14, 2]:
            if let r = tdel.windowCommand(source: self, command: .reportTerminalWindowPixelDimension) {
                sendResponse(r)
            } else {
                let cellSize = tdel.cellSizeInPixels(source: self) ?? (width: 10, height: 16)
                sendResponse(cc.CSI, "4;\(rows * cellSize.height);\(cols * cellSize.width)t")
            }
        case [15]: // Report size in pixels
            if let r = tdel.windowCommand(source: self, command: .reportSizeOfScreenInPixels) {
                sendResponse(r)
            } else {
                let cellSize = tdel.cellSizeInPixels(source: self) ?? (width: 10, height: 16)
                sendResponse(cc.CSI, "5;\(rows * cellSize.height);\(cols * cellSize.width)t")
            }
        case [16]: // Report cell size in pixels
            // If no value is returned send 16x10
            // TODO: should surface that to the UI, should not do this here
            if let r = tdel.windowCommand(source: self, command: .reportCellSizeInPixels) {
                sendResponse(r)
            } else if let cellSize = tdel.cellSizeInPixels(source: self) {
                sendResponse(cc.CSI, "6;\(cellSize.height);\(cellSize.width)t")
            } else {
                sendResponse (cc.CSI, "6;16;10t")
            }
        case [18]:
            if let r = tdel.windowCommand(source: self, command: .reportTextAreaCharacters) {
                sendResponse(r)
            } else {
                sendResponse(cc.CSI, "8;\(rows);\(cols)t")
            }
        case [19]:
            if let r = tdel.windowCommand(source: self, command: .reportScreenSizeCharacters) {
                sendResponse(r)
            } else {
                sendResponse(cc.CSI, "9;\(rows);\(cols)t")
            }
        case [20]:
            // Do not report the actual title back, as it can be exploited,
            // https://marc.info/?l=bugtraq&m=104612710031920&w=2
            sendResponse (cc.OSC, "L", cc.ST)
        case [21]:
            // Do not report the actual content of the title back, as it can be exploited,
            // https://marc.info/?l=bugtraq&m=104612710031920&w=2
            sendResponse (cc.OSC, "l", cc.ST)
        case [22, 0], [22, 0, 0]:
            terminalTitleStack = terminalTitleStack + [terminalTitle]
            terminalIconStack = terminalIconStack + [iconTitle]
        case [22, 1]:
            terminalIconStack = terminalIconStack + [iconTitle]
        case [22, 2]:
            terminalTitleStack = terminalTitleStack + [terminalTitle]
        case [23, 0], [23, 0, 0]:
            if let nt = terminalTitleStack.last {
                terminalTitleStack = terminalTitleStack.dropLast()
                setTitle(text: nt)
            }
            if let nt = terminalIconStack.last {
                terminalIconStack = terminalIconStack.dropLast()
                setIconTitle(text: nt)
            }
        case [23, 1]:
            if let nt = terminalIconStack.last {
                terminalIconStack = terminalIconStack.dropLast()
                setIconTitle(text: nt)
            }
        case [23, 2]:
            if let nt = terminalTitleStack.last {
                terminalTitleStack = terminalTitleStack.dropLast()
                setTitle(text: nt)
            }

        default:
            log ("Unhandled Window command: \(pars)")
            break
        }
    }

    func cmdSetMargins (_ pars: [Int], _ collect: cstring)
    {
        guard collect.isEmpty else { return }

        var left = min (cols-1, max (0, (pars.count > 0 ? pars[0] : 1) - 1))
        let right = min (cols-1, max (0, (pars.count > 1 ? pars [1] : cols) - 1))
        
        left = min (left, right)
        buffer.marginLeft = left
        buffer.marginRight = right
    }
    
    //
    //  CSI s (sometimes, if the margin mode is false)
    //  ESC 7
    //   Save cursor (ANSI.SYS).
    //
    func cmdSaveCursor (_ pars: [Int], _ collect: cstring)
    {
        // CSI s (no intermediates) = ANSI Save Cursor
        // Sequences with intermediates (e.g. CSI > s) are not cursor commands
        guard collect.isEmpty else { return }

        buffer.savedX = buffer.x
        buffer.savedY = buffer.y
        buffer.savedAttr = curAttr
        buffer.savedCharset = charset
        buffer.savedWraparound = wraparound
        buffer.savedOriginMode = originMode
        buffer.savedMarginMode = marginMode
        buffer.savedReverseWraparound = reverseWraparound
    }

    //
    // CSI Ps ; Ps r
    //   Set Scrolling Region [top;bottom] (default = full size of window) (DECSTBM).
    // CSI ? Pm r
    //
    func cmdSetScrollRegion (_ pars: [Int], _ collect: cstring)
    {
        if collect != [] {
            return
        }
        let buffer = self.buffer
        let top = pars.count > 0 ? max (pars [0] - 1, 0) : 0
        var bottom = rows
        if pars.count > 1 {
            // bottom = 0 means "bottom of the screen"
            let p = pars [1]
            if p != 0 {
                bottom = min (pars [1], rows)
            }
        }
        // normalize
        bottom -= 1
        
        // only set the scroll region if top < bottom
        if top < bottom {
            buffer.scrollBottom = bottom
            buffer.scrollTop = top
        }
        setCursor(col: 0, row: 0)
    }

    public func setCursorStyle (_ style: CursorStyle)
    {
        if options.cursorStyle != style {
            options.cursorStyle = style
            tdel?.cursorStyleChanged(source: self, newStyle: style)
        }
    }
    
    //
    // CSI Ps SP q  Set cursor style (DECSCUSR, VT520).
    //   Ps = 0  -> blinking block.
    //   Ps = 1  -> blinking block (default).
    //   Ps = 2  -> steady block.
    //   Ps = 3  -> blinking underline.
    //   Ps = 4  -> steady underline.
    //   Ps = 5  -> blinking bar (xterm).
    //   Ps = 6  -> steady bar (xterm).
    //
    func cmdSetCursorStyle (_ pars: [Int], _ collect: cstring)
    {
        if collect.count == 0 || collect != [32] { /* space */
            return
        }
        let p = pars.count == 0 ? 0 : pars [0]
        switch (p) {
        case 0:
            setCursorStyle(defaultCursorStyle)
        case 1:
            setCursorStyle (.blinkBlock)
        case 2:
            setCursorStyle (.steadyBlock)
        case 3:
            setCursorStyle (.blinkUnderline)
        case 4:
            setCursorStyle (.steadyUnderline)
        case 5:
            setCursorStyle (.blinkBar)
        case 6:
            setCursorStyle (.steadyBar)
        default:
            break;
        }
    }

    func cmdXTVERSION(_ pars: [Int], _ collect: cstring) {
        guard collect == [UInt8(ascii: ">")], pars == [0] else { return }
        let identity = Terminal.xtVersionIdentity(tag: SwiftTermBuildInfo.tag,
                                                  branch: SwiftTermBuildInfo.branch,
                                                  version: SwiftTermBuildInfo.version)
        sendResponse([ControlCodes.ESC, UInt8(ascii: "P")], ">|\(identity)",
                     [ControlCodes.ESC, UInt8(ascii: "\\")])
    }

    static func xtVersionIdentity(tag: String?, branch: String?,
                                  version: String?) -> String {
        func printableASCII(_ value: String?) -> String? {
            guard let value else { return nil }
            let bytes = value.utf8.filter { $0 >= 0x20 && $0 <= 0x7e }
            guard !bytes.isEmpty else { return nil }
            return String(decoding: bytes, as: UTF8.self)
        }

        var identity = "SwiftTerm"
        if var tag = printableASCII(tag) {
            if tag.first == "v" {
                tag.removeFirst()
            }
            if !tag.isEmpty {
                identity += " \(tag)"
            }
        }
        if let branch = printableASCII(branch) {
            identity += "-\(branch)"
        }
        if let version = printableASCII(version), version != "unknown" {
            identity += "+\(version)"
        }
        identity += ":"

        if identity.utf8.count > 256 {
            identity = String(identity.prefix(255)) + ":"
        }
        return identity
    }

    private func setReverseColors(_ enabled: Bool) {
        guard reverseColors != enabled else { return }
        reverseColors = enabled
        updateFullScreen()
        // This existing callback also invalidates color-dependent renderer caches.
        tdel?.colorChanged(source: self, idx: nil)
    }

    private enum BidiStateProperty: Hashable {
        case supportMode
        case autodetectDirection
        case fallbackDirection
        case boxMirroring
    }

    private static let allBidiStateProperties: Set<BidiStateProperty> = [
        .supportMode, .autodetectDirection, .fallbackDirection, .boxMirroring,
    ]

    private func setCurrentBidiState(
        _ state: BidiPresentationState,
        applying properties: Set<BidiStateProperty> = Terminal.allBidiStateProperties
    ) {
        _currentBidiState = state
        normalBuffer.defaultBidiState = state
        altBuffer.defaultBidiState = state
        applyCurrentBidiStateAtParagraphStart(properties: properties)
        updateFullScreen()
    }

    private func updateCurrentBidiState(
        property: BidiStateProperty,
        _ update: (inout BidiPresentationState) -> Void
    ) {
        var state = currentBidiState
        update(&state)
        setCurrentBidiState(state, applying: [property])
    }

    /// A mode change applies to existing text only at the first logical
    /// position of the current paragraph.
    private func applyCurrentBidiStateAtParagraphStart(properties: Set<BidiStateProperty>) {
        let row = buffer.yBase + buffer.y
        guard buffer.x == 0, row >= 0, row < buffer.lines.count else {
            return
        }
        var first = row
        while first > 0 && buffer.lines[first].isWrapped {
            first -= 1
        }
        guard first == row else {
            return
        }
        var last = row
        while last + 1 < buffer.lines.count && buffer.lines[last + 1].isWrapped {
            last += 1
        }
        var paragraphState = buffer.lines[first].bidiState
        if properties.contains(.supportMode) {
            paragraphState.supportMode = currentBidiState.supportMode
        }
        if properties.contains(.autodetectDirection) {
            paragraphState.autodetectDirection = currentBidiState.autodetectDirection
        }
        if properties.contains(.fallbackDirection) {
            paragraphState.fallbackDirection = currentBidiState.fallbackDirection
        }
        if properties.contains(.boxMirroring) {
            paragraphState.boxMirroring = currentBidiState.boxMirroring
        }
        for index in first...last {
            buffer.lines[index].bidiState = paragraphState
        }
    }

    // SCP - Select Character Path: CSI Ps SP k. Ps 1 selects LTR, Ps 2
    // selects RTL, and Ps 0 selects the configured default.
    func cmdSelectCharacterPath(_ pars: [Int], _ collect: cstring) {
        let direction: BidiDirection
        switch pars.first ?? 0 {
        case 0:
            direction = options.initialBidiState.fallbackDirection
        case 1:
            direction = .leftToRight
        case 2:
            direction = .rightToLeft
        default:
            return
        }
        updateCurrentBidiState(property: .fallbackDirection) {
            $0.fallbackDirection = direction
        }
    }

    // SPD is accepted as a compatibility alias for the original patch.
    // CSI 0 SP S selects LTR and CSI 3 SP S selects RTL.
    func cmdSelectPresentationDirection (_ pars: [Int], _ collect: cstring)
    {
        let direction: BidiDirection
        switch pars.first ?? 0 {
        case 0:
            direction = .leftToRight
        case 3:
            direction = .rightToLeft
        default:
            return
        }
        updateCurrentBidiState(property: .fallbackDirection) {
            $0.fallbackDirection = direction
        }
    }

    func cmdSavePrivateModes(_ pars: [Int]) {
        for mode in pars {
            switch mode {
            case 1243:
                savedBidiPrivateModes[mode] = bidiArrowKeySwap
            case 2500:
                savedBidiPrivateModes[mode] = currentBidiState.boxMirroring
            case 2501:
                savedBidiPrivateModes[mode] = currentBidiState.autodetectDirection
            default:
                break
            }
        }
    }

    func cmdRestorePrivateModes(_ pars: [Int]) {
        var state = currentBidiState
        var stateChanged = false
        var restoredProperties: Set<BidiStateProperty> = []
        for mode in pars {
            guard let value = savedBidiPrivateModes[mode] else {
                continue
            }
            switch mode {
            case 1243:
                bidiArrowKeySwap = value
            case 2500:
                state.boxMirroring = value
                stateChanged = true
                restoredProperties.insert(.boxMirroring)
            case 2501:
                state.autodetectDirection = value
                stateChanged = true
                restoredProperties.insert(.autodetectDirection)
            default:
                break
            }
        }
        if stateChanged {
            setCurrentBidiState(state, applying: restoredProperties)
        }
    }

    func cmdDecRqm (_ pars: [Int], decMode: Bool) {
        let modeUnknown = 0
        let modeSet = 1
        let modeReset = 2
        //let modeAlwaysSet = 3
        let modeAlwaysReset = 4
        
        // Same as reset for now, but it is something that should change if the companion setting is ever implemented
        let modeCouldBeImplementedButReset = 2
        let modeCouldBeImplementedButSet = 1
        
        guard let mode = pars.first else {
            sendResponse (cc.CSI, ";0$y")
            return
        }
        var res = modeUnknown
        if decMode {
            switch mode {
            case 1: // DECCKM
                res = applicationCursor ? modeSet : modeReset
            case 2: // DECCKM - reserved for VT52 emulation
                res = modeSet
            case 3: // DECCOLM - 132 Column Mode
                res = buffer.cols == 132 ? modeSet : modeReset
            case 4: // DECSCLM - Smooth/jump scroll, we dont implement
                res = smoothScroll ? modeSet : modeReset
            case 5: // DECSCNM - Reverse Display Colors
                res = reverseColors ? modeSet : modeReset
            case 6: // DECOM - cursor origin
                res = originMode ? modeSet : modeReset
            case 7: // DECAWM - Wraparound Mode
                res = wraparound ? modeSet : modeReset
            case 8: // DECARM - Autorepeat mode
                res = modeCouldBeImplementedButSet
            case 9:
                res = mouseMode == .x10 ? modeSet : modeReset
            case 10:
                res = modeAlwaysReset
            case 12: // ATT610_BLINK
                res = cursorBlink ? modeSet : modeReset
            case 13: // user cursor blink setting
                res = modeCouldBeImplementedButReset
            case 14: // cursor blink xor
                res = modeCouldBeImplementedButReset
            case 18: // DECPFF - Print screen with form feed
                res = modeCouldBeImplementedButSet
            case 19: // DECPEX - print region limitation
                res = modeCouldBeImplementedButSet
            case 25: // DECTCEM cursor visbiolity
                res = cursorHidden ? modeReset : modeSet
            case 30: // RXVT show scrollbar
                res = modeCouldBeImplementedButReset
            case 40: // Enable 80 to 132 transition
                res = allow80To132 ? modeSet : modeReset
            case 41: // xterm tab workaround in "more(1)" command
                res = modeReset
            case 42: // DECNRCM - national character set
                res = modeAlwaysReset
            case 44: // MARGIN_BELL
                res = modeAlwaysReset
            case 45: // REVERSEWRAP
                res = reverseWraparound ? modeSet : modeReset
            case 46: // allow logging
                res = modeAlwaysReset
            case 47: // ALTBUF - alternate screen buffer
                res = isCurrentBufferAlternate ? modeSet : modeReset
            case 66: // DECNKCM
                res = applicationKeypad ? modeSet : modeReset
            case 67: // backspace sends delete
                res = modeAlwaysReset
            case 69: // DECLRMM - mmargins
                res = marginMode ? modeSet : modeReset
            case 80: // DECSDM - Sixel scrolling
                res = modeAlwaysReset
            case 95: // DECNCSM - clear on DECCOLM changes
                res = modeCouldBeImplementedButSet
            case 1000:
                res = mouseMode == .vt200 ? modeSet : modeReset
            case 1001:
                res = modeCouldBeImplementedButReset
            case 1002:
                res = mouseMode == .buttonEventTracking ? modeSet : modeReset
            case 1003:
                res = mouseMode == .anyEvent ? modeSet : modeReset
            case 1004:
                res = sendFocus ? modeSet : modeReset
            case 1005:
                res = mouseProtocol == .utf8 ? modeSet : modeReset
            case 1006:
                res = mouseProtocol == .sgr ? modeSet : modeReset
            case 1007:
                res = alternateScrollMode ? modeSet : modeReset
            case 1015:
                res = mouseProtocol == .urxvt ? modeSet : modeReset
            case 1016:
                res = mouseProtocol == .sgrPixel ? modeSet : modeReset
            case 1034:
                // This is the esc+key toggles top bit, in this UTF world, I dont think it is worth support it ever.
                res = modeAlwaysReset
                // 1035, 1036, 1037, 1039, 1040, 1042, 1043, 1046
                // 1047 - what does this even do?
                // 1048, 1049,
                // keyboard emulation mode: 1050, 1051, 1052, 1053, 1060, 1061
            case 2004:
                res = bracketedPasteMode ? modeSet : modeReset
            case 2026:
                res = synchronizedOutputActive ? modeSet : modeReset
            case 2500: // box drawing mirroring (terminal-wg)
                res = bidiBoxMirroring ? modeSet : modeReset
            case 2501: // autodetect paragraph direction (terminal-wg)
                res = bidiAutodetectDirection ? modeSet : modeReset
            case 1243: // swap left and right arrow keys on RTL paragraphs
                res = bidiArrowKeySwap ? modeSet : modeReset
            case 2031:
                res = colorSchemeUpdatesEnabled ? modeSet : modeReset
            default:
                break
            }
        } else {
            switch mode {
            case 1: // GATM - guarded area transfer
                res = modeAlwaysReset
            case 2: // Disable keyboard input KAM
                // If implemented elsewhere, this can be added here, but I have reservations about this
                res = modeCouldBeImplementedButReset
            case 3: // CRM - Display control characters
                res = modeCouldBeImplementedButReset
            case 4: // IRM Insert mode
                res = insertMode ? modeSet : modeReset
            case 5: // SRTM Status reporting transfer
                res = modeAlwaysReset
            case 7: // VEM vertical editing
                res = modeAlwaysReset
            case 8: // BDSM BiDi support mode (terminal-wg)
                res = bidiSupportEnabled ? modeSet : modeReset
            case 10: // HEM horizontal editing
                res = modeAlwaysReset
            case 11: // PUM positioning unit
                res = modeAlwaysReset
            case 12: // SRM send-receive mode, update when we implement
                res = modeCouldBeImplementedButSet
            case 13: // FEAM Format effector action
                res = modeAlwaysReset
            case 14: // FETM Format effector transfer
                res = modeAlwaysReset
            case 15: // MATM Multiple area transfer
                res = modeAlwaysReset
            case 16: // TTM transfer termination
                res = modeAlwaysReset
            case 17: // SATM selected area transfer
                res = modeAlwaysReset
            case 18: // TSM tabulation stop
                res = modeAlwaysReset
            case 19: // EBM Editing Boundary
                res = modeAlwaysReset
            case 20: // LNM Line feed/newline
                res = lineFeedMode ? modeSet : modeReset
            default:
                break
            }
        }
        if decMode {
            sendResponse (cc.CSI, "?\(mode);\(res)$y")
        } else {
            sendResponse (cc.CSI, "\(mode);\(res)$y")
        }
    }
    
    //
    // Proxy for various CSI .* p commands
    func csiPHandler (_ pars: [Int], _ collect: cstring)
    {
        switch collect {
        case [UInt8 (ascii: "!")]:
            cmdSoftReset ()
        case [UInt8 (ascii: "\"")]:
            cmdSetConformanceLevel (pars, collect)
            
            // DECRQM - CSI ? Pa $ p
            // Request DEC mode
        case [63, 36]:
            cmdDecRqm (pars, decMode: true);
        
            // DECRQM - CSI Pa $ p
            // Request ANSI mode
        case [36]:
            cmdDecRqm (pars, decMode: false);
        default:
            var r = ""
            for x in collect {
                r.append ("\(x)")
            }
            log ("Unhandled CSI \(r) with pars=\(pars)")
        }
    }
    
    // CSI Pl ; Pc " p
    // Set conformance level (DECSCL), VT220 and up
    func cmdSetConformanceLevel (_ pars: [Int], _ collect: cstring)
    {
        if pars.count > 0 {
            let level = pars [0]
            switch level {
            case 61:
                conformance = .vt100
                cc.send8bit = false
            case 62:
                conformance = .vt200
            case 63:
                conformance = .vt300
            case 64:
                conformance = .vt400
            case 65:
                conformance = .vt500
            default:
                conformance = .vt500
            }
        }
        if pars.count > 1 && conformance != .vt100 {
            switch pars [1] {
            case 0:
                cc.send8bit = true
            case 2:
                cc.send8bit = true
            default:
                cc.send8bit = false
            }
        }
    }
    
    //
    // http://vt100.net/docs/vt220-rm/table4-10.html
    //
    /* ! - CSI ! p   Soft terminal reset (DECSTR). */
    func cmdSoftReset ()
    {
        setCurrentBidiState(options.initialBidiState)
        bidiArrowKeySwap = options.initialBidiArrowKeySwap
        savedBidiPrivateModes.removeAll()
        cursorHidden = false
        insertMode = false
        originMode = false

        reverseWraparound = false
        
        setWraparound(true)  // defaults: xterm - true, vt100 - false
        applicationKeypad = false
        syncScrollArea ()
        applicationCursor = false
        buffer.scrollTop = 0
        buffer.scrollBottom = rows - 1
        setCurrentAttribute(CharData.defaultAttr)
        buffer.softReset ()
        resetSemanticPromptState(clearingScreenMarks: true)

        charset = nil
        setgLevel (0)
        conformance = .vt500
        activeHyperlink = nil
        lineFeedMode = options.convertEol
        resetAllColors()
        tdel?.showCursor(source: self)
        // MIGUEL TODO:
        // TODO: audit any new variables, those in setup might be useful
    }

    /// Performs a terminal soft-reset, the equivalent of the DECSTR sequence
    /// For a full reset see `resetToInitialState`
    public func softReset ()
    {
        cmdSoftReset()
    }
    
    //
    // CSI Ps n  Device Status Report (DSR).
    //     Ps = 5  -> Status Report.  Result (``OK'') is
    //   CSI 0 n
    //     Ps = 6  -> Report Cursor Position (CPR) [row;column].
    //   Result is
    //   CSI r ; c R
    // CSI ? Ps n
    //   Device Status Report (DSR, DEC-specific).
    //     Ps = 6  -> Report Cursor Position (CPR) [row;column] as CSI
    //     ? r ; c R (assumes page is zero).
    //     Ps = 1 5  -> Report Printer status as CSI ? 1 0  n  (ready).
    //     or CSI ? 1 1  n  (not ready).
    //     Ps = 2 5  -> Report UDK status as CSI ? 2 0  n  (unlocked)
    //     or CSI ? 2 1  n  (locked).
    //     Ps = 2 6  -> Report Keyboard status as
    //   CSI ? 2 7  ;  1  ;  0  ;  0  n  (North American).
    //   The last two parameters apply to VT400 & up, and denote key-
    //   board ready and LK01 respectively.
    //     Ps = 5 3  -> Report Locator status as
    //   CSI ? 5 3  n  Locator available, if compiled-in, or
    //   CSI ? 5 0  n  No Locator, if not.
    //
    func cmdDeviceStatus (_ pars: [Int], _ collect: cstring)
    {
        let buffer = self.buffer
        if collect.count == 0 {
            switch (pars [0]) {
            case 5:
                // status report
                sendResponse (cc.CSI, "0n")
            case 6:
                // cursor position
                let y = max (1, buffer.y + 1 - (originMode ? buffer.scrollTop : 0))
                
                // Need the max, because the cursor could be before the leftMargin
                let x = max (1, buffer.x + 1 - (originMode ? buffer.marginLeft : 0))
                sendResponse (cc.CSI, "\(y);\(x)R")
            default:
                break;
            }
        } else if (collect == [UInt8 (ascii: "?")]) {
            // modern xterm doesnt seem to
            // respond to any of these except ?6, 6, and 5
            switch pars [0] {
            case 6:
                // cursor position
                let y = buffer.y + 1 - (originMode ? buffer.scrollTop : 0)
                // Need the max, because the cursor could be before the leftMargin
                let x = max (1, buffer.x + 1  - (usingMargins () ? buffer.marginLeft : 0))
                sendResponse (cc.CSI, "?\(y);\(x);1R")
            case 15:
                // Request printer status report, we respond "We are ready"
                sendResponse(cc.CSI, "?10n")
                break;
            case 25:
                // We respond "User defined keys are locked"
                sendResponse(cc.CSI, "?21n")
                break;
            case 26:
                // Requests keyboard type
                // We respond "American keyboard", TODO: worth plugging something else?  Mac perhaps?
                sendResponse(cc.CSI, "?27;1;0;0n")
    
                break;
            case 53:
                // TODO: no dec locator/mouse
                // this.handler(C0.ESC + '[?50n');
                break;
            case 55:
                // Request locator status
                sendResponse(cc.CSI, "?53n")
            case 56:
                // What kind of locator we have, we reply mouse, but perhaps on iOS we should respond something else
                sendResponse(cc.CSI, "?57;1n")
            case 62:
                // Macro space report
                sendResponse(cc.CSI, "0*{")
            case 63:
                // Requests checksum of macros, we return 0
                let id = pars.count > 1 ? pars [1] : 0
                sendResponse(cc.DCS, "\(id)!~0000", cc.ST)
            case 75:
                // Data integrity report, no issues:
                sendResponse (cc.CSI, "?70n")
            case 85:
                // Multiple session status, we reply single session
                sendResponse (cc.CSI, "?83n")
            case 996:
                // Report the current dark/light palette preference.
                reportColorScheme()
            default:
                break
            }
        }
    }

    //
    // CSI Pm m  Character Attributes (SGR).
    //     Ps = 0  -> Normal (default).
    //     Ps = 1  -> Bold.
    //     Ps = 2  -> Faint, decreased intensity (ISO 6429).
    //     Ps = 4  -> Underlined.
    //     Ps = 5  -> Blink (appears as Bold).
    //     Ps = 7  -> Inverse.
    //     Ps = 8  -> Invisible, i.e., hidden (VT300).
    //     Ps = 9  -> Crossed out character
    //     Ps = 2 2  -> Normal (neither bold nor faint).
    //     Ps = 2 4  -> Not underlined.
    //     Ps = 2 5  -> Steady (not blinking).
    //     Ps = 2 7  -> Positive (not inverse).
    //     Ps = 2 8  -> Visible, i.e., not hidden (VT300).
    //     Ps = 2 9  -> Not crossed out
    //     Ps = 3 0  -> Set foreground color to Black.
    //     Ps = 3 1  -> Set foreground color to Red.
    //     Ps = 3 2  -> Set foreground color to Green.
    //     Ps = 3 3  -> Set foreground color to Yellow.
    //     Ps = 3 4  -> Set foreground color to Blue.
    //     Ps = 3 5  -> Set foreground color to Magenta.
    //     Ps = 3 6  -> Set foreground color to Cyan.
    //     Ps = 3 7  -> Set foreground color to White.
    //     Ps = 3 9  -> Set foreground color to default (original).
    //     Ps = 4 0  -> Set background color to Black.
    //     Ps = 4 1  -> Set background color to Red.
    //     Ps = 4 2  -> Set background color to Green.
    //     Ps = 4 3  -> Set background color to Yellow.
    //     Ps = 4 4  -> Set background color to Blue.
    //     Ps = 4 5  -> Set background color to Magenta.
    //     Ps = 4 6  -> Set background color to Cyan.
    //     Ps = 4 7  -> Set background color to White.
    //     Ps = 4 9  -> Set background color to default (original).
    //
    //   If 16-color support is compiled, the following apply.  Assume
    //   that xterm's resources are set so that the ISO color codes are
    //   the first 8 of a set of 16.  Then the aixterm colors are the
    //   bright versions of the ISO colors:
    //     Ps = 9 0  -> Set foreground color to Black.
    //     Ps = 9 1  -> Set foreground color to Red.
    //     Ps = 9 2  -> Set foreground color to Green.
    //     Ps = 9 3  -> Set foreground color to Yellow.
    //     Ps = 9 4  -> Set foreground color to Blue.
    //     Ps = 9 5  -> Set foreground color to Magenta.
    //     Ps = 9 6  -> Set foreground color to Cyan.
    //     Ps = 9 7  -> Set foreground color to White.
    //     Ps = 1 0 0  -> Set background color to Black.
    //     Ps = 1 0 1  -> Set background color to Red.
    //     Ps = 1 0 2  -> Set background color to Green.
    //     Ps = 1 0 3  -> Set background color to Yellow.
    //     Ps = 1 0 4  -> Set background color to Blue.
    //     Ps = 1 0 5  -> Set background color to Magenta.
    //     Ps = 1 0 6  -> Set background color to Cyan.
    //     Ps = 1 0 7  -> Set background color to White.
    //
    //   If xterm is compiled with the 16-color support disabled, it
    //   supports the following, from rxvt:
    //     Ps = 1 0 0  -> Set foreground and background color to
    //     default.
    //
    //   If 88- or 256-color support is compiled, the following apply.
    //     Ps = 3 8  ; 5  ; Ps -> Set foreground color to the second
    //     Ps.
    //     Ps = 4 8  ; 5  ; Ps -> Set background color to the second
    //     Ps.
    //
    func cmdCsiM (_ pars: [Int], _ collect: cstring)
    {
        switch collect.count {
        case 0:
            cmdCharAttributes(pars)
        case 1:
            // Configure Modifier Key Reporting Formats
            // TODO: XTMODKEYS
            if collect[0] == UInt8(ascii: ">") {
                break
            }
        default:
            break
        }
    }

    @inline(__always)
    private func cmdCharAttributes(_ pars: [Int]) {
        // Optimize a single SGR0.
        if pars.count == 1 && pars [0] == 0 {
            setCurrentAttribute(CharData.defaultAttr)
            return;
        }

        let parCount = pars.count
        //let empty = CharacterStyle (attribute: 0)
        var style = curAttr.style
        var fg = curAttr.fg
        var bg = curAttr.bg
        var underlineStyle = curAttr.underlineStyle
        var underlineColor = curAttr.underlineColor
        let def = CharData.defaultAttr

        var i = 0
        
        assert(EscapeSequenceParser.maximumParameterCount <= 64)
        var sepPresent: UInt64 = 0
        var sepIsColon: UInt64 = 0
        var separatorIndex = 0
        let separatorLimit = max(0, pars.count - 1)
        for value in parser._parsTxt where value == 0x3b || value == 0x3a {
            guard separatorIndex < separatorLimit else { break }
            let bit = UInt64(1) << UInt64(separatorIndex)
            sepPresent |= bit
            if value == 0x3a {
                sepIsColon |= bit
            }
            separatorIndex += 1
        }

        func separator(after index: Int) -> UInt8? {
            guard index >= 0 && index < 64 else {
                return nil
            }
            let bit = UInt64(1) << UInt64(index)
            guard sepPresent & bit != 0 else { return nil }
            return sepIsColon & bit != 0 ? 0x3a : 0x3b
        }

        func colonChainEnd(from index: Int) -> Int {
            var end = index
            while end < pars.count - 1, separator(after: end) == 0x3a {
                end += 1
            }
            return end
        }

        func applyUnderlineStyle(code: Int) {
            switch code {
            case 0:
                style.remove(.underline)
                underlineStyle = .none
            case 1:
                style = [style, .underline]
                underlineStyle = .single
            case 2:
                style = [style, .underline]
                underlineStyle = .double
            case 3:
                style = [style, .underline]
                underlineStyle = .curly
            case 4:
                style = [style, .underline]
                underlineStyle = .dotted
            case 5:
                style = [style, .underline]
                underlineStyle = .dashed
            default:
                style = [style, .underline]
                underlineStyle = .single
            }
        }

        func parseExtendedColor(startIndex: Int, usesColon: Bool) -> (Attribute.Color?, Int) {
            guard startIndex < pars.count else {
                return (nil, 0)
            }
            let kind = pars[startIndex]
            if usesColon {
                let end = colonChainEnd(from: startIndex)
                let chainLength = end - startIndex + 1
                switch kind {
                case 2:
                    if chainLength >= 5 {
                        let red = pars[startIndex + 2]
                        let green = pars[startIndex + 3]
                        let blue = pars[startIndex + 4]
                        return (Attribute.Color.trueColor(red: UInt8(min(red, 255)),
                                                         green: UInt8(min(green, 255)),
                                                         blue: UInt8(min(blue, 255))),
                                chainLength)
                    } else if chainLength >= 4 {
                        let red = pars[startIndex + 1]
                        let green = pars[startIndex + 2]
                        let blue = pars[startIndex + 3]
                        return (Attribute.Color.trueColor(red: UInt8(min(red, 255)),
                                                         green: UInt8(min(green, 255)),
                                                         blue: UInt8(min(blue, 255))),
                                chainLength)
                    }
                case 5:
                    if chainLength >= 2 {
                        let code = pars[startIndex + 1]
                        return (Attribute.Color.ansi256(code: UInt8(min(255, code))), chainLength)
                    }
                default:
                    break
                }
                return (nil, chainLength)
            } else {
                switch kind {
                case 2:
                    if startIndex + 3 < pars.count {
                        let red = pars[startIndex + 1]
                        let green = pars[startIndex + 2]
                        let blue = pars[startIndex + 3]
                        return (Attribute.Color.trueColor(red: UInt8(min(red, 255)),
                                                         green: UInt8(min(green, 255)),
                                                         blue: UInt8(min(blue, 255))),
                                4)
                    }
                case 5:
                    if startIndex + 1 < pars.count {
                        let code = pars[startIndex + 1]
                        return (Attribute.Color.ansi256(code: UInt8(min(255, code))), 2)
                    }
                default:
                    break
                }
            }
            return (nil, 1)
        }

        // Extended Colors
        //
        // There is an ambiguity here that is troublesome, to support extended
        // colors and colorspaces, two competing systems exists, one uses for example:
        // 38;2;R;G;B;NEXT - foreground true color
        // 38:2:ColorSpace:R:G:B:REST;NEXT - second style for the same
        //
        // The former apparently was a mistake, but we need to disambiguate the meaning
        // of pars, based on whether the above uses ":" or ";" we need that, because
        // the SGR is a collection of attributes, so after our parameter values, we
        // need to continue processing
        func parseExtendedColor () -> Attribute.Color? {
            let usesColon = separator(after: i - 1) == 0x3a
            let parsed = parseExtendedColor(startIndex: i, usesColon: usesColon)
            i += max(parsed.1, 1)
            return parsed.0
        }
        
        while i < parCount {
            var p = pars [i]
            switch p {
            case 0:
                // default
                style = def.style
                fg = def.fg
                bg = def.bg
                underlineStyle = def.underlineStyle
                underlineColor = def.underlineColor
            case 1:
                // bold text
                style = [style, .bold]
            case 2:
                // dimmed text
                style = [style, .dim]
            case 3:
                // italic text
                style = [style, .italic]
            case 4:
                if separator(after: i) == 0x3a, i + 1 < parCount {
                    applyUnderlineStyle(code: pars[i + 1])
                    i += 2
                    continue
                } else {
                    // underlined text
                    style = [style, .underline]
                    underlineStyle = .single
                }
            case 5:
                // blink
                style = [style, .blink]
            case 7:
                // inverse and positive
                // test with: echo -e '\e[31m\e[42mhello\e[7mworld\e[27mhi\e[m'
                style = [style, .inverse]
            case 8:
                // invisible
                style = [style, .invisible]
            case 9:
                style = [style, .crossedOut]
            case 21:
                // double underline
                style = [style, .underline]
                underlineStyle = .double
            case 22:
                // not bold nor faint
                style.remove (.bold)
                style.remove (.dim)
            case 23:
                // not italic
                style.remove (.italic)
            case 24:
                // not underlined
                style.remove (.underline)
                underlineStyle = .none
            case 25:
                // not blink
                style.remove (.blink)
            case 27:
                // not inverse
                style.remove (.inverse)
            case 28:
                // not invisible
                style.remove (.invisible)
            case 29:
                // not crossed out
                style.remove (.crossedOut)
            case 30...37:
                // fg color 8
                fg = Attribute.Color.ansi256(code: UInt8(p - 30))
            case 38:
                i += 1
                if let parsed = parseExtendedColor () {
                    fg = parsed
                }
                continue
            case 39:
                // reset fg
                fg = CharData.defaultAttr.fg
            case 40...47:
                // bg color 8
                bg = Attribute.Color.ansi256(code: UInt8(p - 40))
            case 48:
                i += 1
                if let parsed = parseExtendedColor() {
                    bg = parsed
                }
                continue
                
            case 49:
                // reset bg
                bg = CharData.defaultAttr.bg
            case 90...97:
                // fg color 16
                p += 8
                fg = Attribute.Color.ansi256(code: UInt8(p - 90))
            case 100...107:
                // bg color 16
                p += 8;
                bg = Attribute.Color.ansi256(code: UInt8(p - 100))
                
            case 58:
                i += 1
                if let parsed = parseExtendedColor() {
                    underlineColor = parsed
                }
                continue

            case 59:
                // reset underline color
                underlineColor = nil
                
            default:
                print ("Unknown SGR attribute: \(p) \(pars)")
            }
            i += 1
        }
        setCurrentAttribute(Attribute(fg: fg,
                                      bg: bg,
                                      style: style,
                                      underlineStyle: underlineStyle,
                                      underlineColor: underlineColor))
    }

    //
    //CSI Pm l  Reset Mode (RM).
    //    Ps = 2  -> Keyboard Action Mode (AM).
    //    Ps = 4  -> Replace Mode (IRM).
    //    Ps = 1 2  -> Send/receive (SRM).
    //    Ps = 2 0  -> Normal Linefeed (LNM).
    //CSI ? Pm l
    //  DEC Private Mode Reset (DECRST).
    //    Ps = 1  -> Normal Cursor Keys (DECCKM).
    //    Ps = 2  -> Designate VT52 mode (DECANM).
    //    Ps = 3  -> 80 Column Mode (DECCOLM).
    //    Ps = 4  -> Jump (Fast) Scroll (DECSCLM).
    //    Ps = 5  -> Normal Video (DECSCNM).
    //    Ps = 6  -> Normal Cursor Mode (DECOM).
    //    Ps = 7  -> No Wraparound Mode (DECAWM).
    //    Ps = 8  -> No Auto-repeat Keys (DECARM).
    //    Ps = 9  -> Don't send Mouse X & Y on button press.
    //    Ps = 1 0  -> Hide toolbar (rxvt).
    //    Ps = 1 2  -> Stop Blinking Cursor (att610).
    //    Ps = 1 8  -> Don't print form feed (DECPFF).
    //    Ps = 1 9  -> Limit print to scrolling region (DECPEX).
    //    Ps = 2 5  -> Hide Cursor (DECTCEM).
    //    Ps = 3 0  -> Don't show scrollbar (rxvt).
    //    Ps = 3 5  -> Disable font-shifting functions (rxvt).
    //    Ps = 4 0  -> Disallow 80 -> 132 Mode.
    //    Ps = 4 1  -> No more(1) fix (see curses resource).
    //    Ps = 4 2  -> Disable Nation Replacement Character sets (DEC-
    //    NRCM).
    //    Ps = 4 4  -> Turn Off Margin Bell.
    //    Ps = 4 5  -> No Reverse-wraparound Mode.
    //    Ps = 4 6  -> Stop Logging.  (This is normally disabled by a
    //    compile-time option).
    //    Ps = 4 7  -> Use Normal Screen Buffer.
    //    Ps = 6 6  -> Numeric keypad (DECNKM).
    //    Ps = 6 7  -> Backarrow key sends delete (DECBKM).
    //    Ps = 1 0 0 0  -> Don't send Mouse X & Y on button press and
    //    release.  See the section Mouse Tracking.
    //    Ps = 1 0 0 1  -> Don't use Hilite Mouse Tracking.
    //    Ps = 1 0 0 2  -> Don't use Cell Motion Mouse Tracking.
    //    Ps = 1 0 0 3  -> Don't use All Motion Mouse Tracking.
    //    Ps = 1 0 0 4  -> Don't send FocusIn/FocusOut events.
    //    Ps = 1 0 0 5  -> Disable Extended Mouse Mode.
    //    Ps = 1 0 0 7  -> Disable Alternate Scroll Mode, xterm.  This
    //    corresponds to the alternateScroll resource.
    //    Ps = 1 0 1 0  -> Don't scroll to bottom on tty output
    //    (rxvt).
    //    Ps = 1 0 1 1  -> Don't scroll to bottom on key press (rxvt).
    //    Ps = 1 0 3 4  -> Don't interpret "meta" key.  (This disables
    //    the eightBitInput resource).
    //    Ps = 1 0 3 5  -> Disable special modifiers for Alt and Num-
    //    Lock keys.  (This disables the numLock resource).
    //    Ps = 1 0 3 6  -> Don't send ESC  when Meta modifies a key.
    //    (This disables the metaSendsEscape resource).
    //    Ps = 1 0 3 7  -> Send VT220 Remove from the editing-keypad
    //    Delete key.
    //    Ps = 1 0 3 9  -> Don't send ESC  when Alt modifies a key.
    //    (This disables the altSendsEscape resource).
    //    Ps = 1 0 4 0  -> Do not keep selection when not highlighted.
    //    (This disables the keepSelection resource).
    //    Ps = 1 0 4 1  -> Use the PRIMARY selection.  (This disables
    //    the selectToClipboard resource).
    //    Ps = 1 0 4 2  -> Disable Urgency window manager hint when
    //    Control-G is received.  (This disables the bellIsUrgent
    //    resource).
    //    Ps = 1 0 4 3  -> Disable raising of the window when Control-
    //    G is received.  (This disables the popOnBell resource).
    //    Ps = 1 0 4 7  -> Use Normal Screen Buffer, clearing screen
    //    first if in the Alternate Screen.  (This may be disabled by
    //    the titeInhibit resource).
    //    Ps = 1 0 4 8  -> Restore cursor as in DECRC.  (This may be
    //    disabled by the titeInhibit resource).
    //    Ps = 1 0 4 9  -> Use Normal Screen Buffer and restore cursor
    //    as in DECRC.  (This may be disabled by the titeInhibit
    //    resource).  This combines the effects of the 1 0 4 7  and 1 0
    //    4 8  modes.  Use this with terminfo-based applications rather
    //    than the 4 7  mode.
    //    Ps = 1 0 5 0  -> Reset terminfo/termcap function-key mode.
    //    Ps = 1 0 5 1  -> Reset Sun function-key mode.
    //    Ps = 1 0 5 2  -> Reset HP function-key mode.
    //    Ps = 1 0 5 3  -> Reset SCO function-key mode.
    //    Ps = 1 0 6 0  -> Reset legacy keyboard emulation (X11R6).
    //    Ps = 1 0 6 1  -> Reset keyboard emulation to Sun/PC style.
    //    Ps = 2 0 0 4  -> Reset bracketed paste mode.
    //
    func cmdResetMode (_ pars: [Int], _ collect: cstring)
    {
        if pars.count == 0 {
            return
        }

        if pars.count > 1 {
            for i in 0..<pars.count {
                resetMode (pars [i], collect)
            }
            return
        }
        resetMode (pars [0], collect)
    }

    func resetMode (_ par: Int, _ collect: cstring)
    {
        if collect == [] {
            switch (par) {
            case 2:
                // KAM mode - unlocks the keyboard, not supported
                break
            case 4:
                // IRM Insert/Replace Mode
                setInsertMode(false)
            case 8:
                // BDSM explicit mode: present logical order, app does BiDi
                updateCurrentBidiState(property: .supportMode) { $0.supportMode = .explicit }
            case 20:
                // LNM—Line Feed/New Line Mode
                lineFeedMode = false
                break
            default:
                break
            }
        } else if collect == [UInt8 (ascii: "?")] {
            switch (par) {
            case 1:
                applicationCursor = false
            case 3:
                if allow80To132 {
                    // DECCOLM
                    resize (cols: 80, rows: rows)
                    tdel?.sizeChanged(source: self)
                    resetToInitialState()
                }
            case 4: // DECSCLM - Jump scroll mode
                smoothScroll = false
                break
            case 5:
                setReverseColors(false)
            case 6:
                // DECOM Reset
                originMode = false
            case 7:
                setWraparound(false)
            case 12:
                cursorBlink = false
            case 40:
                allow80To132 = false
            case 41:
                // Workaround not implemented 
                break
            case 45:
                reverseWraparound = false
            case 66:
                //log ("Switching back to normal keypad.");
                applicationKeypad = false
                syncScrollArea ()
            case 69:
                // DECSLRM
                setMarginMode(false)
            case 9: // X10 Mouse
                mouseMode = .off
            case 1000: // vt200 mouse
                mouseMode = .off
            case 95: // DECNCSM - clear on DECCOLM changes
                // unsupported
                break
            case 1002: // button event mouse
                mouseMode = .off
            case 1003: // any event mouse
                mouseMode = .off
            case 1004: // send focusin/focusout events
                sendFocus = false
            case 1007: // alternate scroll mode (xterm's alternateScroll resource)
                alternateScrollMode = false
            case 2500: // box drawing mirroring off
                updateCurrentBidiState(property: .boxMirroring) { $0.boxMirroring = false }
            case 2501: // autodetect off: use the SPD-selected direction
                updateCurrentBidiState(property: .autodetectDirection) { $0.autodetectDirection = false }
            case 1243:
                bidiArrowKeySwap = false
            case 1005: // utf8 ext mode mouse
                // Resets the coordinate encoding only: 1005/1006/1015/1016 select how mouse
                // events are encoded, independent of the tracking modes (9/1000-1003). xterm
                // keeps tracking enabled when an encoding is reset; turning mouseMode off here
                // broke clients (e.g. mosh re-asserts modes as "CSI ?1003l ?1003h ?1006l ?1006h"
                // on every resize, which left tracking permanently disabled).
                mouseProtocol = .x10
            case 1006: // sgr ext mode mouse
                mouseProtocol = .x10
            case 1015: // urxvt ext mode mouse
                mouseProtocol = .x10
            case 1016: // sgrPixel mode
                mouseProtocol = .x10
            case 25: // hide cursor
                hideCursor ()
            case 1048: // alt screen cursor
                cmdRestoreCursor ([], [])
            case 1034:
                // Terminal.app ignores this request, and keeps sending ESC+letter
                break
            case 1049: // alt screen buffer cursor
                fallthrough
            case 47: // normal screen buffer
                fallthrough
            case 1047: // normal screen buffer - clearing it first
                   // Ensure the selection manager has the correct buffer
                activateNormalBuffer(clearAlt: par == 1047 || par == 1049)
                if (par == 1049){
                    cmdRestoreCursor ([], [])
                }
                refresh (startRow: 0, endRow: rows - 1)
                syncScrollArea ()
                showCursor ()
                tdel?.bufferActivated(source: self)
                
            case 2004: // bracketed paste mode (https://cirw.in/blog/bracketed-paste)
                bracketedPasteMode = false
                break
            case 2026: // synchronized output (https://github.com/contour-terminal/vt-extensions)
                endSynchronizedOutput ()
            case 2031: // color-scheme update notifications
                colorSchemeUpdatesEnabled = false
            default:
                log ("Unhandled DEC Private Mode Reset (DECRST) with \(par)")
                break
            }
        }
    }

    //
    // CSI Pm h  Set Mode (SM).
    //     Ps = 2  -> Keyboard Action Mode (AM).
    //     Ps = 4  -> Insert Mode (IRM).
    //     Ps = 1 2  -> Send/receive (SRM).
    //     Ps = 2 0  -> Automatic Newline (LNM).
    // CSI ? Pm h
    //   DEC Private Mode Set (DECSET).
    //     Ps = 1  -> Application Cursor Keys (DECCKM).
    //     Ps = 2  -> Designate USASCII for character sets G0-G3
    //     (DECANM), and set VT100 mode.
    //     Ps = 3  -> 132 Column Mode (DECCOLM).
    //     Ps = 4  -> Smooth (Slow) Scroll (DECSCLM).
    //     Ps = 5  -> Reverse Video (DECSCNM).
    //     Ps = 6  -> Origin Mode (DECOM).
    //     Ps = 7  -> Wraparound Mode (DECAWM).
    //     Ps = 8  -> Auto-repeat Keys (DECARM).
    //     Ps = 9  -> Send Mouse X & Y on button press.  See the sec-
    //     tion Mouse Tracking.
    //     Ps = 1 0  -> Show toolbar (rxvt).
    //     Ps = 1 2  -> Start Blinking Cursor (att610).
    //     Ps = 1 8  -> Print form feed (DECPFF).
    //     Ps = 1 9  -> Set print extent to full screen (DECPEX).
    //     Ps = 2 5  -> Show Cursor (DECTCEM).
    //     Ps = 3 0  -> Show scrollbar (rxvt).
    //     Ps = 3 5  -> Enable font-shifting functions (rxvt).
    //     Ps = 3 8  -> Enter Tektronix Mode (DECTEK).
    //     Ps = 4 0  -> Allow 80 -> 132 Mode.
    //     Ps = 4 1  -> more(1) fix (see curses resource).
    //     Ps = 4 2  -> Enable Nation Replacement Character sets (DECN-
    //     RCM).
    //     Ps = 4 4  -> Turn On Margin Bell.
    //     Ps = 4 5  -> Reverse-wraparound Mode.
    //     Ps = 4 6  -> Start Logging.  This is normally disabled by a
    //     compile-time option.
    //     Ps = 4 7  -> Use Alternate Screen Buffer.  (This may be dis-
    //     abled by the titeInhibit resource).
    //     Ps = 6 6  -> Application keypad (DECNKM).
    //     Ps = 6 7  -> Backarrow key sends backspace (DECBKM).
    //     Ps = 1 0 0 0  -> Send Mouse X & Y on button press and
    //     release.  See the section Mouse Tracking.
    //     Ps = 1 0 0 1  -> Use Hilite Mouse Tracking.
    //     Ps = 1 0 0 2  -> Use Cell Motion Mouse Tracking.
    //     Ps = 1 0 0 3  -> Use All Motion Mouse Tracking.
    //     Ps = 1 0 0 4  -> Send FocusIn/FocusOut events.
    //     Ps = 1 0 0 5  -> Enable Extended Mouse Mode.
    //     Ps = 1 0 0 7  -> Enable Alternate Scroll Mode, xterm.  This
    //     corresponds to the alternateScroll resource.
    //     Ps = 1 0 1 0  -> Scroll to bottom on tty output (rxvt).
    //     Ps = 1 0 1 1  -> Scroll to bottom on key press (rxvt).
    //     Ps = 1 0 3 4  -> Interpret "meta" key, sets eighth bit.
    //     (enables the eightBitInput resource).
    //     Ps = 1 0 3 5  -> Enable special modifiers for Alt and Num-
    //     Lock keys.  (This enables the numLock resource).
    //     Ps = 1 0 3 6  -> Send ESC   when Meta modifies a key.  (This
    //     enables the metaSendsEscape resource).
    //     Ps = 1 0 3 7  -> Send DEL from the editing-keypad Delete
    //     key.
    //     Ps = 1 0 3 9  -> Send ESC  when Alt modifies a key.  (This
    //     enables the altSendsEscape resource).
    //     Ps = 1 0 4 0  -> Keep selection even if not highlighted.
    //     (This enables the keepSelection resource).
    //     Ps = 1 0 4 1  -> Use the CLIPBOARD selection.  (This enables
    //     the selectToClipboard resource).
    //     Ps = 1 0 4 2  -> Enable Urgency window manager hint when
    //     Control-G is received.  (This enables the bellIsUrgent
    //     resource).
    //     Ps = 1 0 4 3  -> Enable raising of the window when Control-G
    //     is received.  (enables the popOnBell resource).
    //     Ps = 1 0 4 7  -> Use Alternate Screen Buffer.  (This may be
    //     disabled by the titeInhibit resource).
    //     Ps = 1 0 4 8  -> Save cursor as in DECSC.  (This may be dis-
    //     abled by the titeInhibit resource).
    //     Ps = 1 0 4 9  -> Save cursor as in DECSC and use Alternate
    //     Screen Buffer, clearing it first.  (This may be disabled by
    //     the titeInhibit resource).  This combines the effects of the 1
    //     0 4 7  and 1 0 4 8  modes.  Use this with terminfo-based
    //     applications rather than the 4 7  mode.
    //     Ps = 1 0 5 0  -> Set terminfo/termcap function-key mode.
    //     Ps = 1 0 5 1  -> Set Sun function-key mode.
    //     Ps = 1 0 5 2  -> Set HP function-key mode.
    //     Ps = 1 0 5 3  -> Set SCO function-key mode.
    //     Ps = 1 0 6 0  -> Set legacy keyboard emulation (X11R6).
    //     Ps = 1 0 6 1  -> Set VT220 keyboard emulation.
    //     Ps = 2 0 0 4  -> Set bracketed paste mode.
    // Modes:
    //   http: *vt100.net/docs/vt220-rm/chapter4.html
    //
    func cmdSetMode (_ pars: [Int], _ collect: cstring)
    {
        if pars.count == 0 {
            return
        }

        if pars.count > 1 {
            for i in 0..<pars.count {
                setMode (pars [i], collect)
            }
            return
        }
        setMode (pars [0], collect)
    }

    func setMode (_ par: Int, _ collect: cstring)
    {
        if (collect == []) {
            switch par {
            case 2:
                // KAM mode - unlocks the keyboard, I do not want to support it
                break
            case 4:
                // IRM Insert/Replace Mode
                // https://vt100.net/docs/vt510-rm/IRM.html
                setInsertMode(true)
            case 8:
                // BDSM implicit mode: the terminal performs BiDi reordering
                updateCurrentBidiState(property: .supportMode) { $0.supportMode = .implicit }
//            case 12:
//                 SRM—Local Echo: Send/Receive Mode
//                 When implemented, hook up cmdDecRqm
//                break
            case 20:
                // Automatic New Line (LNM)
                lineFeedMode = true
                break;
            default:
                log ("Unhandled verbatim setMode with \(par) and \(collect)")
                break
            }
        } else if collect == [UInt8 (ascii: "?")] {
            switch par {
            case 1:
                applicationCursor = true
            case 2:
                setgCharset (0, charset: CharSets.defaultCharset)
                setgCharset (1, charset: CharSets.defaultCharset)
                setgCharset (2, charset: CharSets.defaultCharset)
                setgCharset (3, charset: CharSets.defaultCharset)
                // set VT100 mode here
                
            case 3: // DECCOLM - go to 132 col mode
                if allow80To132 {
                    resize (cols: 132, rows: rows)
                    resetToInitialState()
                    tdel?.sizeChanged(source: self)
                }
            case 4: // Smooth scroll mode
                smoothScroll = true
                break
            case 5:
                setReverseColors(true)
            case 6:
                // DECOM Set
                originMode = true
            case 7:
                setWraparound(true)
            case 12:
                cursorBlink = true
                break;
            case 40:
                allow80To132 = true
            case 66:
                //log ("Serial port requested application keypad.")
                applicationKeypad = true
                syncScrollArea ()
            case 9:
                // X10 Mouse
                mouseMode = .x10
            case 45: // Xterm Reverse Wrap-around
                // reverse wraparound can only be enabled if Auto-wrap is enabled (DECAWM)
                if wraparound {
                    reverseWraparound = true
                }
            case 69:
                // Enable left and right margin mode (DECLRMM),
                setMarginMode(true)
            case 95: // DECNCSM - clear on DECCOLM changes
                // unsupported
                break
            case 1000:
                // SET_VT200_HIGHLIGHT_MOUSE
                mouseMode = .vt200
            case 1002:
                // SET_BTN_EVENT_MOUSE
                mouseMode = .buttonEventTracking

            case 1003:
                // SET_ANY_EVENT_MOUSE
                mouseMode = .anyEvent

            case 1004: // send focusin/focusout events
                   // focusin: ^[[I
                   // focusout: ^[[O
                sendFocus = true
                // Report the current state right away (xterm behavior), so
                // the application does not assume it is unfocused until the
                // first real focus change.
                sendFocusReport()
            case 1007: // alternate scroll mode (xterm's alternateScroll resource)
                alternateScrollMode = true
            case 2500: // box drawing mirroring (terminal-wg)
                updateCurrentBidiState(property: .boxMirroring) { $0.boxMirroring = true }
            case 2501: // autodetect paragraph direction (terminal-wg)
                updateCurrentBidiState(property: .autodetectDirection) { $0.autodetectDirection = true }
            case 1243:
                bidiArrowKeySwap = true
            case 1005:
                // utf8 ext mode mouse
                mouseProtocol = .utf8
                break;
            case 1006: // sgr ext mode mouse
                mouseProtocol = .sgr
            case 1015: // urxvt ext mode mouse
                mouseProtocol = .urxvt
            case 1016: // sgrPixel mode
                mouseProtocol = .sgrPixel
            case 25: // show cursor
                showCursor()
            case 63:
                // DECRLM - Cursor Right to Left Mode, not supported
                break
            case 1034:
                // Terminal.app ignores this request, and keeps sending ESC+letter
                // Given our UTF8 world, I do not think this is a worth encoding
                break
            case 1048: // alt screen cursor
                cmdSaveCursor ([], [])
            case 1049: // alt screen buffer cursor
                cmdSaveCursor ([], [])
                // FALL-THROUGH
                fallthrough
            case 47: // alt screen buffer
                fallthrough
            case 1047: // alt screen buffer
                activateAltBuffer (fillAttr: nil)
                refresh (startRow: 0, endRow: rows - 1)
                syncScrollArea ()
                showCursor ()
                tdel?.bufferActivated(source: self)
                
            case 2004: // bracketed paste mode (https://cirw.in/blog/bracketed-paste)
                // TODO: must implement bracketed paste mode
                bracketedPasteMode = true
            case 2026: // synchronized output (https://github.com/contour-terminal/vt-extensions)
                beginSynchronizedOutput ()
            case 2031: // color-scheme update notifications
                colorSchemeUpdatesEnabled = true
            default:
                log ("Unhandled DEC Private Mode Set (DECSET) with \(par)")
                break;
            }
        } else {
            log ("Unhandled setMode (SM) with \(par) and \(collect)")
        }
        
    }


    //
    // CSI Ps g  Tab Clear (TBC).
    //     Ps = 0  -> Clear Current Column (default).
    //     Ps = 3  -> Clear All.
    // Potentially:
    //   Ps = 2  -> Clear Stops on Line.
    //   http://vt100.net/annarbor/aaa-ug/section6.html
    //
    func cmdTabClear (_ pars: [Int], _ collect: cstring)
    {
        let p = pars.count == 0 ? 0 : pars [0]
        if p == 0 {
            buffer.tabClear(pos: buffer.x)
        } else if (p == 3) {
            buffer.clearTabStops ()
        }
    }


    //
    // CSI Ps ; Ps f
    //   Horizontal and Vertical Position [row;column] (default =
    //   [1,1]) (HVP).
    //
    func cmdHVPosition (_ pars: [Int], _ collect: cstring)
    {
        var p = 1
        var q = 1
        if pars.count > 0 {
            p = max (pars [0], 1)
            if (pars.count > 1){
                q = max (pars [1], 1)
            }
        }
        
        buffer.y = p - 1 + (originMode ? buffer.scrollTop : 0)
        if buffer.y >= rows {
            buffer.y = rows - 1
        }
        
        buffer.x = q - 1 + (originMode && marginMode ? buffer.marginLeft : 0)
        if buffer.x >= cols {
            buffer.x = cols - 1
        }
    }

    //
    // CSI Pm e  Vertical Position Relative (VPR)
    //   [rows] (default = [row+1,column])
    // reuse CSI Ps B ?
    //
    func cmdVPositionRelative (_ pars: [Int], _ collect: cstring)
    {
        let p = max (pars.count == 0 ? 1 : pars [0], 1)
        let newY = buffer.y + p

        if newY >= rows {
            buffer.y = rows - 1
        } else {
            buffer.y = newY
        }

        // If the end of the line is hit, prevent this action from wrapping around to the next line.
        if buffer.x >= cols {
            buffer.x -= 1
        }
    }


    //
    // CSI Pm d  Vertical Position Absolute (VPA)
    //   [row] (default = [1,column])
    //
    func cmdLinePosAbsolute (_ pars: [Int], _ collect: cstring)
    {
        let p = max (pars.count == 0 ? 1 : pars [0], 1)

        if (p - 1 >= rows) {
            buffer.y = rows - 1
        } else {
            buffer.y = p - 1
        }
    }

    //
    // CSI Ps c  Send Device Attributes (Primary DA).
    //     Ps = 0  or omitted -> request attributes from terminal.  The
    //     response depends on the decTerminalID resource setting.
    //     -> CSI ? 1 ; 2 c  (``VT100 with Advanced Video Option'')
    //     -> CSI ? 1 ; 0 c  (``VT101 with No Options'')
    //     -> CSI ? 6 c  (``VT102'')
    //     -> CSI ? 6 0 ; 1 ; 2 ; 6 ; 8 ; 9 ; 1 5 ; c  (``VT220'')
    //   The VT100-style response parameters do not mean anything by
    //   themselves.  VT220 parameters do, telling the host what fea-
    //   tures the terminal supports:
    //     Ps = 1  -> 132-columns.
    //     Ps = 2  -> Printer.
    //     Ps = 4  -> Sixel graphics
    //     Ps = 6  -> Selective erase.
    //     Ps = 8  -> User-defined keys.
    //     Ps = 9  -> National replacement character sets.
    //     Ps = 1 5  -> Technical characters.
    //     Ps = 2 2  -> ANSI color, e.g., VT525.
    //     Ps = 2 9  -> ANSI text locator (i.e., DEC Locator mode).
    // CSI > Ps c
    //   Send Device Attributes (Secondary DA).
    //     Ps = 0  or omitted -> request the terminal's identification
    //     code.  The response depends on the decTerminalID resource set-
    //     ting.  It should apply only to VT220 and up, but xterm extends
    //     this to VT100.
    //     -> CSI  > Pp ; Pv ; Pc c
    //   where Pp denotes the terminal type
    //     Pp = 0  -> ``VT100''.
    //     Pp = 1  -> ``VT220''.
    //   and Pv is the firmware version (for xterm, this was originally
    //   the XFree86 patch number, starting with 95).  In a DEC termi-
    //   nal, Pc indicates the ROM cartridge registration number and is
    //   always zero.
    // More information:
    //   xterm/charproc.c - line 2012, for more information.
    //   vim responds with ^[[?0c or ^[[?1c after the terminal's response (?)
    //
    func cmdSendDeviceAttributes (_ pars: [Int], _ collect: cstring)
    {
        if pars.count > 0 && pars [0] > 0 {
            let safe = String(decoding: collect.prefix { $0 != 0 }, as: UTF8.self)
            log ("SendDeviceAttributes got \(pars) and \(safe)")
            return
        }

        if collect == [UInt8 (ascii: ">")] || collect == [UInt8 (ascii: ">"), UInt8 (ascii: "0")] {
            // DA2 Secondary Device Attributes
            if pars.count == 0 || pars [0] == 0 {
                let vt525 = 65 // we identified as a vt525
                let kbd = 1 // PC-style keyboard
                sendResponse(cc.CSI, ">\(vt525);20;\(kbd)c")
                return
            }
            log ("Got a CSI > c with an unknown set of argument")
            return
        }
        
        // We should use a terminal emulation level, and not rely on the TERM name
        // for now, "xterm" as a part of the name surfaces all the capabilities.
        let name = options.termName
        if collect == [] {
            let termVt525 = 65
            let sixel = options.enableSixelReported ? ";4" : ""
            let cols132 = 1
            let printer = 2
            let decsera = 6
            let terminalStateInterrogation = 17
            let horizontalScrolling = 21
            let ansiColor = 22
            let rectangularEditing = 28
            
            // Send Device Attributes (Primary DA).1
            if name.hasPrefix("xterm") {
                sendResponse (cc.CSI, "?\(termVt525)\(sixel);\(cols132);\(printer);\(decsera);\(horizontalScrolling);\(ansiColor);\(terminalStateInterrogation);\(rectangularEditing)c")
            } else if name.hasPrefix("screen") || name.hasPrefix ("rxvt-unicode") {
                sendResponse (cc.CSI, "?\(cols132);\(printer)c")
            } else if name.hasPrefix ("linux") {
                sendResponse (cc.CSI, "?\(decsera)c")
            }
        } else if collect.count == 1 && collect [0] == UInt8 (ascii: ">") {
            // xterm and urxvt
            // seem to spit this
            // out around ~370 times (?).
            if name.hasPrefix ("xterm") {
                sendResponse (cc.CSI, ">0;276;0c")
            } else if name.hasPrefix ("rxvt-unicode") {
                sendResponse (cc.CSI, ">85;95;0c")
            } else if name.hasPrefix ("linux") {
                // not supported by linux console.
                // linux console echoes parameters.
                sendResponse ("\(pars[0])c")
            } else if name.hasPrefix ("screen") {
                sendResponse (cc.CSI, ">83;40003;0c")
            }
        }
    }


    //
    // CSI Ps b  Repeat the preceding graphic character Ps times (REP).
    //
    func cmdRepeatPrecedingCharacter (_ pars: [Int], _ collect: cstring)
    {
        // Maximum repeat, to avoid a denial of service
        let maxRepeat = cols*rows*2
        let p = min (maxRepeat, max (pars.count == 0 ? 1 : pars [0], 1))
        let line = buffer.lines [buffer.yBase + buffer.y]
        let cell = buffer.x > 0 ? line.packedCell(at: buffer.x - 1) : PackedCell()
        
        for _ in 0..<p {
            buffer.insertCharacter(cell)
        }
    }

    //
    //CSI Pm a  Character Position Relative
    //  [columns] (default = [row,col+1]) (HPR)
    //reuse CSI Ps C ?
    //
    func cmdHPositionRelative (_ pars: [Int], _ collect: cstring)
    {
        let p = max (pars.count == 0 ? 1 : pars [0], 1)
        
        buffer.x += p
        if buffer.x >= cols {
            buffer.x = cols - 1
        }
    }

    //
    // CSI Pm `  Character Position Absolute
    //   [column] (default = [row,1]) (HPA).
    //
    func cmdCharPosAbsolute (_ pars: [Int], _ collect: cstring)
    {
        let p = max (pars.count == 0 ? 1 : pars [0], 1)

        buffer.x = p - 1
        if buffer.x >= cols {
            buffer.x = cols - 1
        }
    }

    //
    //CSI Ps Z  Cursor Backward Tabulation Ps tab stops (default = 1) (CBT).
    //
    func cmdCursorBackwardTab (_ pars: [Int], _ collect: cstring)
    {
        if buffer.x > cols {
            return
        }
        let p = min (buffer.cols, max (pars.count == 0 ? 1 : pars [0], 1))

        for _ in 0..<p {
            buffer.x = buffer.previousTabStop ()
        }
    }

    //
    // CSI Ps X
    // Erase Ps Character(s) (default = 1) (ECH).
    //
    func cmdEraseChars (_ pars: [Int], _ collect: cstring)
    {
        let p = max (pars.count == 0 ? 1 : pars [0], 1)

        buffer.lines[buffer.y + buffer.yBase].replacePackedCells(
            start: buffer.x,
            end: buffer.x + p,
            fill: currentEraseBlankCell)
    }

    func csiT (_ pars: [Int], _ collect: cstring)
    {
        if collect.count == 0 {
            cmdScrollDown(pars)
        } else if collect == [UInt8 (ascii: ">")] {
            cmdXtermTitleModeReset(pars)
        }
    }
    //
    // CSI Ps T  Scroll down Ps lines (default = 1) (SD).
    //
    func cmdScrollDown (_ pars: [Int])
    {
        let p = min (max (pars.count == 0 ? 1 : pars [0], 1), rows)
        let defaultBlank = PackedCell()

        if marginMode {
            let row = buffer.scrollTop + buffer.yBase

            let columnCount = buffer.marginRight-buffer.marginLeft+1
            let rowCount = buffer.scrollBottom-buffer.scrollTop
            for _ in 0..<p {
                for i in (0..<rowCount).reversed() {
                    let src = buffer.lines [row+i]
                    let dst = buffer.lines [row+i+1]

                    dst.copyFrom(src, srcCol: buffer.marginLeft, dstCol: buffer.marginLeft, len: columnCount)
                }
                let last = buffer.lines [row]
                last.fill(with: defaultBlank,
                          atCol: buffer.marginLeft, len: columnCount)
            }

            selectionsInvalidateForColumnRestrictedScroll (top: row, bottom: row + rowCount, left: buffer.marginLeft, right: buffer.marginRight)
        } else {
            for _ in 0..<p {
                buffer.lines.splice (start: buffer.yBase + buffer.scrollBottom, deleteCount: 1,
                                     items: [], change: { line in updateRange (line)})
                buffer.lines.splice (start: buffer.yBase + buffer.scrollTop, deleteCount: 0,
                                     items: [buffer.getBlankLine(packedBlank: defaultBlank)],
                                     change: { line in updateRange (line) })
            }

            let top = buffer.yBase + buffer.scrollTop
            let bottom = buffer.yBase + buffer.scrollBottom
            selectionsAdjustForInPlaceScroll (top: top, bottom: bottom, lines: -p)
        }
        if hasKittyPlacements {
            scrollKittyPlacementsInMargins(
                top: buffer.yBase + buffer.scrollTop,
                bottom: buffer.yBase + buffer.scrollBottom,
                left: marginMode ? buffer.marginLeft : 0,
                right: marginMode ? buffer.marginRight : cols - 1,
                delta: p)
        }
        hardenBidiScrollBoundaries(insertedAtTop: true, count: p)
        // this.maxRange();
        refreshScrolledRegion(top: buffer.scrollTop, bottom: buffer.scrollBottom, canBlit: false)
    }

    //
    // CSI Ps S  Scroll up Ps lines (default = 1) (SU).
    //
    func cmdScrollUp (_ pars: [Int], _ collect: cstring)
    {
        let p = min (rows*2, max (pars.count == 0 ? 1 : pars [0], 1))
        let defaultBlank = PackedCell()

        if marginMode {
            let row = buffer.scrollTop + buffer.yBase

            let columnCount = buffer.marginRight-buffer.marginLeft+1
            let rowCount = buffer.scrollBottom-buffer.scrollTop
            for _ in 0..<p {
                for i in 0..<(rowCount) {
                    let src = buffer.lines [row+i+1]
                    let dst = buffer.lines [row+i]
                    
                    dst.copyFrom(src, srcCol: buffer.marginLeft, dstCol: buffer.marginLeft, len: columnCount)
                }
                let last = buffer.lines [row+rowCount]
                last.fill(with: defaultBlank,
                          atCol: buffer.marginLeft, len: columnCount)
            }

            selectionsInvalidateForColumnRestrictedScroll (top: row, bottom: row + rowCount, left: buffer.marginLeft, right: buffer.marginRight)
        } else {
            for _ in 0..<p {
                buffer.lines.splice (start: buffer.yBase + buffer.scrollTop, deleteCount: 1,
                                     items: [], change: { line in updateRange (line)})
                buffer.lines.splice (start: buffer.yBase + buffer.scrollBottom, deleteCount: 0,
                                     items: [buffer.getBlankLine(packedBlank: defaultBlank)],
                                     change: { line in updateRange (line) })
            }

            let top = buffer.yBase + buffer.scrollTop
            let bottom = buffer.yBase + buffer.scrollBottom
            selectionsAdjustForInPlaceScroll (top: top, bottom: bottom, lines: p)
        }
        if hasKittyPlacements {
            scrollKittyPlacementsInMargins(
                top: buffer.yBase + buffer.scrollTop,
                bottom: buffer.yBase + buffer.scrollBottom,
                left: marginMode ? buffer.marginLeft : 0,
                right: marginMode ? buffer.marginRight : cols - 1,
                delta: -p)
        }
        hardenBidiScrollBoundaries(insertedAtTop: false, count: p)
        // this.maxRange();
        refreshScrolledRegion(top: buffer.scrollTop, bottom: buffer.scrollBottom, canBlit: false)
    }

    private func hardenBidiScrollBoundaries(insertedAtTop: Bool, count: Int) {
        let top = buffer.yBase + buffer.scrollTop
        let bottom = buffer.yBase + buffer.scrollBottom
        guard top >= 0, top < buffer.lines.count else {
            return
        }
        buffer.lines[top].isWrapped = false
        let regionHeight = bottom - top + 1
        if insertedAtTop, count < regionHeight {
            let firstMovedRow = top + count
            if firstMovedRow < buffer.lines.count {
                buffer.lines[firstMovedRow].isWrapped = false
            }
        }
        if bottom + 1 < buffer.lines.count {
            buffer.lines[bottom + 1].isWrapped = false
        }
    }

    /// Line insertion and deletion preserve the state stored with moved rows,
    /// but they change which rows are adjacent. Break each new seam so a moved
    /// continuation row cannot attach to a blank or unrelated row.
    private func hardenBidiLineShiftBoundaries(firstChangedRow: Int,
                                                firstMovedRow: Int?,
                                                lastChangedRow: Int) {
        if firstChangedRow >= 0, firstChangedRow < buffer.lines.count {
            buffer.lines[firstChangedRow].isWrapped = false
        }
        if let firstMovedRow,
           firstMovedRow >= 0, firstMovedRow < buffer.lines.count {
            buffer.lines[firstMovedRow].isWrapped = false
        }
        if lastChangedRow + 1 < buffer.lines.count {
            buffer.lines[lastChangedRow + 1].isWrapped = false
        }
    }

    //
    // CSI Ps P
    // Delete Ps Character(s) (default = 1) (DCH).
    //
    func cmdDeleteChars (_ pars: [Int], _ collect: cstring)
    {
        let buffer = self.buffer
        var p = max (pars.count == 0 ? 1 : pars [0], 1)
        
        if marginMode {
            if buffer.x < buffer.marginLeft || buffer.x > buffer.marginRight {
                return
            }
            if buffer.x + p > buffer.marginRight {
                p = buffer.marginRight - buffer.x + 1
            }
        }
        // buffer.x = buffer.cols is a special case on the edge, we do not delete columns in that boundary
        if buffer.x == buffer.cols {
            return
        }
        buffer.lines[buffer.y + buffer.yBase].deletePackedCells(
            pos: buffer.x, n: p,
            rightMargin: marginMode ? buffer.marginRight : cols - 1,
            fill: currentEraseBlankCell)
        
        updateRange (buffer.y)
    }

    //
    // CSI Ps M
    // Delete Ps Line(s) (default = 1) (DL).
    //
    func cmdDeleteLines (_ pars: [Int], _ collect: cstring)
    {
        restrictCursor()
        let buffer = self.buffer
        // No point deleting more lines than the available rows, prevents
        // a denial of service caused by very large numbers passed here
        let p = min (buffer.rows+1, max (pars.count == 0 ? 1 : pars [0], 1))
        let row = buffer.y + buffer.yBase
        var j = rows - 1 - buffer.scrollBottom
        j = rows - 1 + buffer.yBase - j
        let eraseBlank = currentEraseBlankCell
        
        if marginMode {
            if buffer.x >= buffer.marginLeft && buffer.x <= buffer.marginRight {
                let columnCount = buffer.marginRight-buffer.marginLeft+1
                let rowCount = buffer.scrollBottom-buffer.scrollTop
                for _ in 0..<p {
                    for i in 0..<(rowCount) {
                        let src = buffer.lines [row+i+1]
                        let dst = buffer.lines [row+i]
                        
                        dst.copyFrom(src, srcCol: buffer.marginLeft, dstCol: buffer.marginLeft, len: columnCount)
                    }
                    
                    let last = buffer.lines [row+rowCount]
                    last.fill(with: eraseBlank,
                              atCol: buffer.marginLeft, len: columnCount)
                }

                selectionsInvalidateForColumnRestrictedScroll (top: row, bottom: row + rowCount, left: buffer.marginLeft, right: buffer.marginRight)
            }
        } else {
            if buffer.y >= buffer.scrollTop && buffer.y <= buffer.scrollBottom {
                for _ in 0..<p {
                    // test: echo -e '\e[44m\e[1M\e[0m'
                    // blankLine(true) - xterm/linux behavior
                    buffer.lines.splice (start: row, deleteCount: 1, items: [], change: { line in updateRange (line)})
                    buffer.lines.splice (start: j, deleteCount: 0,
                                         items: [buffer.getBlankLine(packedBlank: eraseBlank)],
                                         change: { line in updateRange (line)})
                }

                // Rows below the cursor moved up in place.
                selectionsAdjustForInPlaceScroll (top: row, bottom: j, lines: p)
                hardenBidiLineShiftBoundaries(firstChangedRow: row,
                                               firstMovedRow: nil,
                                               lastChangedRow: j)
            }
        }
        
        // this.maxRange();
        updateRange (startLine: buffer.y, endLine: buffer.scrollBottom)
        // A restricted region leaves stale pixels / a bottom-edge ghost outside
        // [y, scrollBottom] on the CG renderer (as in scroll()); the range above
        // already covers full-screen, so widen to the whole viewport only when the
        // region is restricted.
        refreshScrolledRegion(top: buffer.scrollTop, bottom: buffer.scrollBottom, canBlit: true)
    }

    //
    // CSI Ps ' ~
    // Delete Ps Column(s) (default = 1) (DECDC), VT420 and up.
    //
    // @vt: #Y CSI DECDC "Delete Columns"  "CSI Ps ' ~"  "Delete `Ps` columns at cursor position."
    // DECDC deletes `Ps` times columns at the cursor position for all lines with the scroll margins,
    // moving content to the left. Blank columns are added at the right margin.
    // DECDC has no effect outside the scrolling margins.

    func cmdDeleteColumns (_ pars: [Int], _ collect: cstring)
    {
        let buffer = self.buffer
        if buffer.y > buffer.scrollBottom || buffer.y < buffer.scrollTop {
            return
        }
        // buffer.x = buffer.cols is a special case on the edge, we do not delete columns in that boundary
        if buffer.x == buffer.cols {
            return
        }
        if marginMode {
            if buffer.x < buffer.marginLeft || buffer.x > buffer.marginRight {
                return
            }
        }

        let p = max (pars.count == 0 ? 1 : pars [0], 1)
        
        for y in buffer.scrollTop...buffer.scrollBottom {
            let line = buffer.lines [buffer.yBase + y]
            line.deletePackedCells(
                pos: buffer.x, n: p,
                rightMargin: marginMode ? buffer.marginRight : cols - 1,
                fill: currentEraseSpaceCell)
            line.isWrapped = false
        }
        updateRange (startLine: buffer.scrollTop, endLine: buffer.scrollBottom)
    }


    //
    // Helper method to reset cells in a terminal row.
    // The cell gets replaced with the eraseChar of the terminal and the isWrapped property is set to false.
    // @param y row index
    //
    func resetBufferLine (y: Int, clearImages: Bool = false,
                          bidiState: BidiPresentationState? = nil)
    {
        eraseInBufferLine (y: y, start: 0, end: cols, clearWrap: true, clearRenderMode: true, clearImages: clearImages)
        if let bidiState {
            buffer.lines[buffer.yBase + y].bidiState = bidiState
        }
        updateRange(y)
    }

    /**
     * Sends the provided text to the connected backend
     */
    public func sendResponse (text: String)
    {
        tdel?.send (source: self, data: ([UInt8] (text.utf8))[...])
    }
    
    /**
     * Sends the provided text to the connected backend, takes a variable list of arguments
     * that could be either [UInt8], Strings, or a single UInt8 value.
     */
    public func sendResponse (_ items: Any ...)
    {
        var buffer: [UInt8] = []
        
        for item in items {
            if let arr = item as? [UInt8] {
                buffer.append(contentsOf: arr)
            } else if let str = item as? String {
                buffer.append (contentsOf: [UInt8] (str.utf8))
            } else if let c = item as? UInt8 {
                buffer.append (c)
            } else {
                log ("Do not know how to handle type \(item)")
            }
        }
        tdel?.send (source: self, data: buffer[...])
    }
    
#if DEBUG
    public var silentLog = false
#else
    public var silentLog = true
#endif
    
    // The message is an autoclosure: `silentLog` is true in release builds, and
    // an eagerly built argument makes every caller pay for the interpolation it
    // then throws away. The parser error handler runs on the parse thread and
    // reflects over its state on each malformed sequence, which measured at
    // ~10% of parse time before this became lazy.
    func error (_ text: @autoclosure () -> String)
    {
        if !silentLog {
            print("Error: \(text())")
        }
    }

    func log (_ text: @autoclosure () -> String)
    {
        if !silentLog {
            print("Info: \(text())")
        }
    }
    
    /**
     * Processes the provided byte-array coming from the host, interprets them and
     * updates the screen state accordingly. The caller synchronizes via
     * `terminalLock`.
     */
    public func feed (byteArray: [UInt8])
    {
        parse (buffer: byteArray[...])
    }
    
    /**
     * Processes the provided byte-array coming from the host, interprets them and
     * updates the screen state accordingly. The caller synchronizes via
     * `terminalLock`.
     */
    public func feed (text: String)
    {
        parse (buffer: ([UInt8] (text.utf8))[...])
    }

    /**
     * Processes the provided byte-array coming from the host, interprets them and
     * updates the screen state accordingly. The caller synchronizes via
     * `terminalLock`.
     */
    public func feed (buffer: ArraySlice<UInt8>)
    {
        parse (buffer: buffer)
    }

    /// Processes one borrowed parser batch synchronously.
    func feedBorrowed(_ bytes: Span<UInt8>)
    {
        parseBorrowed(bytes)
    }

    /// Runs a feed that an owner, such as TerminalView or HeadlessTerminal,
    /// controls. Terminal keeps the normal delegate behavior. Internal
    /// subclasses can remove callbacks that their owners handle at the batch
    /// boundary.
    @inline(__always)
    func withManagedFeed<T> (_ body: () throws -> T) rethrows -> T
    {
        return try body()
    }

    /**
     * Processes the provided byte-array coming from the host, interprets them and
     * updates the screen state accordingly. The caller synchronizes via
     * `terminalLock`.
     */
    public func parse (buffer: ArraySlice<UInt8>)
    {
        parseDepth += 1
        defer {
            parseDepth -= 1
            if parseDepth == 0 {
                deliverPendingScrollNotification()
            }
        }
        parser.parse(data: buffer, self)
    }

    /// Parses one borrowed batch and completes all parser effects before return.
    private func parseBorrowed(_ bytes: Span<UInt8>)
    {
        parseDepth += 1
        defer {
            parseDepth -= 1
            if parseDepth == 0 {
                deliverPendingScrollNotification()
            }
        }
        parser.parseBorrowed(bytes, self)
    }

    /// Records a scroll and delivers it immediately when no parse operation is
    /// active. The immediate path preserves the behavior of direct `scroll()`
    /// calls.
    private func recordScrollNotification ()
    {
        hasPendingScrollNotification = true
        if parseDepth == 0 {
            deliverPendingScrollNotification()
        }
    }

    private func deliverPendingScrollNotification ()
    {
        guard hasPendingScrollNotification else { return }
        hasPendingScrollNotification = false
        tdel?.scrolled(source: self, yDisp: buffer.yDisp)
    }
     
    /**
     * Registers the given line as requiring to be updated by the front-end engine
     *
     * The front-end engine should call `getUpdateRange` to
     * determine which region in the screen needs to be redrawn.   This method adds the specified
     * line to the range of modified lines
     *
     * Scrolling tells if this was just issued as part of scrolling which we don't register for the
     * scroll-invariant update ranges.
     */
    func updateRange (_ y: Int, scrolling: Bool = false)
    {        
        if !scrolling {
            let effectiveY = buffer._yDisp + y
            if effectiveY >= 0 {
                if effectiveY < scrollInvariantRefreshStart {
                    scrollInvariantRefreshStart = effectiveY
                }
                if effectiveY > scrollInvariantRefreshEnd {
                    scrollInvariantRefreshEnd = effectiveY
                }
            }
        }
        
        if y >= 0 {
            if y < refreshStart {
                refreshStart = y
            }
            if y > refreshEnd {
                refreshEnd = y
            }
        }
    }

    func updateRange (borrowing buffer: borrowing Buffer, _ y: Int, scrolling: Bool = false)
    {
        if !scrolling {
            let effectiveY = buffer._yDisp + y
            if effectiveY >= 0 {
                if effectiveY < scrollInvariantRefreshStart {
                    scrollInvariantRefreshStart = effectiveY
                }
                if effectiveY > scrollInvariantRefreshEnd {
                    scrollInvariantRefreshEnd = effectiveY
                }
            }
        }

        if y >= 0 {
            if y < refreshStart {
                refreshStart = y
            }
            if y > refreshEnd {
                refreshEnd = y
            }
        }
    }

    func updateRange (startLine: Int, endLine: Int, scrolling: Bool = false)
    {
        updateRange (startLine, scrolling: scrolling)
        updateRange (endLine, scrolling: scrolling)
    }
    
    public func updateFullScreen ()
    {
        refreshStart = 0
        refreshEnd = rows
        
        scrollInvariantRefreshStart = buffer.yDisp
        scrollInvariantRefreshEnd = buffer.yDisp + rows
    }
    
    /**
     * Returns the starting and ending lines that need to be redrawn, or nil
     * if no part of the screen needs to be updated.   Alternatively, you can
     * get a Set<Int> with the changed lines by calling `changedLines()`.
     *
     * UI toolkits should call `clearUpdateRange` to reset these changes
     * after they have used this information, so that new changes only reflect
     * the actual changes.
     */
    public func getUpdateRange () -> (startY: Int, endY: Int)?
    {
        if refreshEnd == -1 && refreshStart == Int.max {
            //print ("Emtpy update range")
            return nil
        }
        //print ("Update: \(refreshStart) \(refreshEnd)")
        return (refreshStart, refreshEnd)
    }

    /**
     * Check for payload identifiers that are not in use and stop retaining their payload,
     * to avoid accumulting memory for images and URLs that are no longer visible or
     * available by scrolling.
     */
    public func garbageCollectPayload() {
        if payloadCodes.isEmpty {
            return
        }
        
        // check all atoms used in both buffers
        var used = Set<UInt16>()
        if let activeHyperlink, case .resolved(let atom) = activeHyperlink {
            used.insert(atom.code)
        }
        for buffer in [normalBuffer, altBuffer] {
            // TODO use a better system than this ugly nest
            for line in buffer.lines.getArray() {
                if let array = line?.getData() {
                    for data in array {
                        let code = data.payload.code
                        if code > 0 {
                            used.insert(code)
                        }
                    }
                }
            }
        }
        
        let released = payloadCodes.subtracting(used)
        if !released.isEmpty {
            TinyAtom.release(codes: released)
            payloadCodes.subtract(released)
        }
    }
    
    /**
     * Returns the starting and ending lines that need to be redrawn, or nil
     * if no part of the screen needs to be updated.
     *
     * This is different from getUpdateRange() in that lines are from start of scroll back,
     * not what the terminal has visible right now.
     */
    public func getScrollInvariantUpdateRange () -> (startY: Int, endY: Int)?
    {
        if scrollInvariantRefreshEnd == -1 && scrollInvariantRefreshStart == Int.max {
            //print ("Emtpy update range")
            return nil
        }
        //print ("Update: \(scrollInvariantRefreshStart) \(scrollInvariantRefreshEnd)")
        return (scrollInvariantRefreshStart, scrollInvariantRefreshEnd)
    }
    
    /**
     * Clears the state of the pending display redraw region as well as the dirtyLines set.
     */
    public func clearUpdateRange ()
    {
        refreshStart = Int.max
        refreshEnd = -1
        
        scrollInvariantRefreshStart = Int.max
        scrollInvariantRefreshEnd = -1
    }
    
    /**
     * Zero-based (row, column) of cursor location relative to visible part of display.
     * Returns: a tuple, where the first element contains the column (x) and the second the row (y) where the cursor is.
     */
    public func getCursorLocation() -> (x: Int, y: Int) {
        return (buffer.x, buffer.y)
    }
    
    /**
     * Returns the uppermost visible row on the terminal buffer
     */
    public func getTopVisibleRow() -> Int {
        return buffer.yDisp
    }
    
    // ESC c Full Reset (RIS)
    /// This performs a full reset of the terminal, like a soft reset, but additionally resets the buffer conents and scroll area.
    /// for a soft reset see `softReset`
    public func resetToInitialState ()
    {
        setCurrentBidiState(options.initialBidiState)
        bidiArrowKeySwap = options.initialBidiArrowKeySwap
        savedBidiPrivateModes.removeAll()
        endSynchronizedOutput ()
        options.rows = rows
        options.cols = cols
        let savedCursorHidden = cursorHidden
        setup (isReset: true)
        clearAllKittyImages()
        cursorHidden = savedCursorHidden
        refresh (startRow: 0, endRow: rows-1)
        syncScrollArea ()
        // A full reset replaces the buffer, so the view's scroll geometry — which
        // is derived from `lines.count` and `yDisp` — is stale. `syncScrollArea()`
        // is a no-op stub, and none of the other paths that recompute it fire
        // here (no buffer switch, no scrolled line, no keystroke, no resize), so
        // notify explicitly. Without this the view keeps the contentSize and
        // contentOffset of a buffer that no longer exists and renders blank until
        // some unrelated layout pass happens to correct it.
        tdel?.bufferActivated (source: self)
    }

    // Support for:
    // ESC 6 Back Index (DECBI) and
    // ESC 9 Forward Index (DECFI)
    func columnIndex (back: Bool)
    {
        let buffer = self.buffer
        let x = buffer.x
        let leftMargin = buffer.marginLeft
        if back {
            if x == leftMargin {
                columnScroll (back: back, at: x)
            } else {
                cursorBackward(count: 1)
            }
        } else {
            let rightMargin = buffer.marginRight
            if x == rightMargin  {
                columnScroll (back: back, at: leftMargin)
            } else if x == buffer.cols {
                // on the boundaries, we ignore, test_DECFI_WholeScreenScrolls
            } else {
                cursorForward(count: 1)
            }
        }
    }
    
    func columnScroll (back: Bool, at: Int)
    {
        if buffer.y < buffer.scrollTop || buffer.y > buffer.scrollBottom || buffer.x < buffer.marginLeft || buffer.x > buffer.marginRight {
            return
        }
        for y in buffer.scrollTop...buffer.scrollBottom {
            let line = buffer.lines [buffer.yBase + y]
            if back {
                line.insertPackedCells(
                    pos: at, n: 1,
                    rightMargin: marginMode ? buffer.marginRight : cols - 1,
                    fill: buffer.getPackedNullCell())
            } else {
                line.deletePackedCells(
                    pos: at, n: 1,
                    rightMargin: marginMode ? buffer.marginRight : cols - 1,
                    fill: currentEraseSpaceCell)
            }
            //line.isWrapped = false
        }
        updateRange (buffer.scrollTop)
        updateRange (buffer.scrollBottom)
    }
    
    // ESC D Index (Index is 0x84) - IND
    func cmdIndex ()
    {
        restrictCursor()

        let buffer = self.buffer
        let newY = buffer.y + 1

        // When left/right margins are active, only scroll if cursor is within margins
        let canScroll = !marginMode || (buffer.x >= buffer.marginLeft && buffer.x <= buffer.marginRight)

        var movedToNextLine = false
        if newY > buffer.scrollBottom {
            if canScroll {
                scroll ()
                movedToNextLine = true
            }
        } else {
            buffer.y = newY
            movedToNextLine = true
        }
        // If the end of the line is hit, prevent this action from wrapping around to the next line
        if buffer.x > cols {
            buffer.x -= 1
        }
        finishSemanticLineAdvance(movedToNextLine: movedToNextLine)
    }
    
    /// Flag the scrolled region dirty. The CoreGraphics renderer now clears any
    /// dirtied region before painting (see AppleTerminalView), so flagging just
    /// [top, bottom] fixes the stale rows / bottom ghost — no whole-viewport repaint
    /// needed. Full-screen + scrollback (`canBlit`) keeps the cheap path.
    private func refreshScrolledRegion(top: Int, bottom: Int, canBlit: Bool) {
        if top != 0 || bottom != rows - 1 || !canBlit {
            updateRange(startLine: top, endLine: bottom)
        }
    }

    public func scroll (isWrapped: Bool = false)
    {
        let buffer = self.buffer
        let lines = buffer.lines
        let scrollTop = buffer.scrollTop
        let scrollBottom = buffer.scrollBottom
        let bMarginLeft = buffer.marginLeft
        let bMarginRight = buffer.marginRight
        let hasScrollback = buffer.hasScrollback
        let topRow = buffer.yBase + scrollTop
        let bottomRow = buffer.yBase + scrollBottom
        var kittyInPlaceScroll = false
        var kittyTrimmedScrollback = false
        let newLineState: BidiPresentationState
        if isWrapped, bottomRow >= 0, bottomRow < lines.count {
            newLineState = lines[bottomRow].bidiState
        } else {
            newLineState = currentBidiState
        }

        let eraseBlank = currentEraseBlankCell

        // When margin mode is active with left/right margins that are narrower than full width,
        // we cannot use scrollback (can't push partial lines), so we do in-place scrolling
        // within the margin columns only. This path is unconditional when narrow margins are
        // active, regardless of cursor position, to ensure consistent behavior.
        let hasNarrowMargins = marginMode && (bMarginLeft > 0 || bMarginRight < cols - 1)
        if hasNarrowMargins {
            kittyInPlaceScroll = true
            let scrollRegionHeight = bottomRow - topRow + 1
            let columnCount = bMarginRight - bMarginLeft + 1
            // Shift content up within the margin columns only.
            //
            // LIMITATION: Line-level metadata (isWrapped, images, renderMode) cannot be
            // partially scrolled, so we reset them on all affected lines.
            //
            // Ideally, isWrapped would be tracked per-column-range so that triple-click
            // selection in one pane selects the wrapped logical line within that pane only.
            // However, isWrapped is currently a per-BufferLine property (spanning all columns),
            // so there's no way to represent "wrapped in cols 0-39, not wrapped in cols 40-79".
            // Implementing column-aware wrapping would require architectural changes to the
            // data model. For now, we clear isWrapped since partial-column scrolling breaks
            // the line-level wrapping semantic.
            //
            for i in 0..<(scrollRegionHeight - 1) {
                let src = lines[topRow + i + 1]
                let dst = lines[topRow + i]
                dst.copyFrom(src, srcCol: bMarginLeft, dstCol: bMarginLeft, len: columnCount)
                dst.isWrapped = false
                dst.bidiState = src.bidiState
                buffer.clearImagesFromLine(at: topRow + i)
                dst.renderMode = .single
            }

            // Clear the bottom row within the margin columns.
            let bottomLine = lines[bottomRow]
            bottomLine.fill(with: eraseBlank,
                            atCol: bMarginLeft, len: columnCount)
            bottomLine.isWrapped = false
            bottomLine.bidiState = currentBidiState
            buffer.clearImagesFromLine(at: bottomRow)
            bottomLine.renderMode = .single

            selectionsInvalidateForColumnRestrictedScroll (top: topRow, bottom: bottomRow, left: bMarginLeft, right: bMarginRight)
        } else if scrollTop == 0 && (bottomRow == lines.count - 1 || hasScrollback) {
            // A partial region at the top of the normal buffer moves its first
            // row into scrollback. Keep the splice path for that case.
            // Determine whether the buffer is going to be trimmed after insertion.
            let willBufferBeTrimmed = lines.isFull

            // Insert the line using the fastest method
            if bottomRow == lines.count - 1 {
                if willBufferBeTrimmed {
                    lines.recycle(clearCell: eraseBlank, isWrapped: isWrapped,
                                  bidiState: newLineState)
                } else {
                    lines.push(buffer.getBlankLine(packedBlank: eraseBlank,
                                                   isWrapped: isWrapped,
                                                   bidiState: newLineState))
                }
            } else {
                let newLine = buffer.getBlankLine(packedBlank: eraseBlank,
                                                  isWrapped: isWrapped,
                                                  bidiState: newLineState)
                lines.splice (start: bottomRow + 1, deleteCount: 0,
                                     items: [newLine],
                                     change: { line in updateRange (line)})
            }

            // Only adjust ybase and ydisp when the buffer is not trimmed
            if !willBufferBeTrimmed {
                buffer.yBase += 1
                // Only scroll the ydisp with ybase if the user has not scrolled up
                if !userScrolling {
                    buffer.yDisp += 1
                }
            } else {
                kittyTrimmedScrollback = true
                if hasScrollback {
                    buffer.linesTop += 1
                }

                // Recycling removes the first buffer row and shifts every
                // remaining row up without changing yDisp.
                selectionsAdjustForInPlaceScroll (top: 0, bottom: lines.count - 1, lines: 1)

                // When the buffer is full and the user has scrolled up, keep the text
                // stable unless ydisp is right at the top
                if userScrolling {
                    buffer.yDisp = max (buffer.yDisp - 1, 0)
                }
            }
        } else {
            kittyInPlaceScroll = true
            // This region does not add a line to scrollback. Shift it in place.

            // Ensure the indices are within bounds to prevent crash (related to issue #256)
            // This can happen when the buffer has been trimmed and yBase is stale
            guard bottomRow < lines.count else {
                print ("scroll: bottomRow \(bottomRow) >= lines.count \(lines.count), state: yBase=\(buffer.yBase) scrollTop=\(scrollTop) scrollBottom=\(scrollBottom) isAlternate=\(isCurrentBufferAlternate)")
                return
            }

            if !lines.shiftUpAndRecycle(top: topRow, bottom: bottomRow,
                                        clearCell: eraseBlank,
                                        isWrapped: isWrapped,
                                        bidiState: newLineState) {
                print ("Assertion on scroll, state was: bottomRow=\(bottomRow) topRow=\(topRow) yDisp=\(buffer.yDisp) linesTop=\(buffer.linesTop) isAlternate=\(isCurrentBufferAlternate)")
            }

            // The rows moved but yDisp did not, so any selection anchored to
            // absolute rows in this region now points at different text.
            selectionsAdjustForInPlaceScroll (top: topRow, bottom: bottomRow, lines: 1)
        }

        // Move the viewport to the bottom of the buffer unless the user is
        // scrolling.
        if !userScrolling {
            buffer.yDisp = buffer.yBase
        }

        if hasKittyPlacements {
            if kittyTrimmedScrollback {
                trimKittyPlacementRows()
            } else if kittyInPlaceScroll {
                scrollKittyPlacementsInMargins(
                    top: topRow,
                    bottom: bottomRow,
                    left: marginMode ? bMarginLeft : 0,
                    right: marginMode ? bMarginRight : cols - 1,
                    delta: -1)
            }
        }

        //buffer.dump ()
        // Flag rows that need updating
        updateRange (scrollTop, scrolling: true)
        updateRange (scrollBottom, scrolling: true)

        refreshScrolledRegion(top: scrollTop, bottom: scrollBottom, canBlit: hasScrollback)

        /**
         * This event is emitted whenever the terminal is scrolled.
         * The one parameter passed is the new y display position.
         *
         * @event scroll
         */
        recordScrollNotification()
    }
        
    public func emitLineFeed ()
    {
        tdel?.linefeed(source: self)
    }
    
    //
    // ESC n
    // ESC o
    // ESC |
    // ESC }
    // ESC ~
    //   DEC mnemonic: LS (https://vt100.net/docs/vt510-rm/LS.html)
    //   When you use a locking shift, the character set remains in GL or GR until
    //   you use another locking shift. (partly supported)
    //
    func setgLevel (_ v: UInt8)
    {
        gLevel = v
        let index = Int(v)
        if index < gCharsets.count {
            charset = gCharsets[index]
        } else {
            charset = nil
        }
    }
    
    //
    // ESC % @
    // ESC % G
    //   Select default character set. UTF-8 is not supported (string are unicode anyways)
    //   therefore ESC % G does the same.
    //
    func cmdSelectDefaultCharset ()
    {
        setgLevel (0)
        setgCharset (0, charset: CharSets.defaultCharset)
    }

    //
    // ESC c
    //   DEC mnemonic: RIS (https://vt100.net/docs/vt510-rm/RIS.html)
    //   Reset to initial state.
    //
    func cmdReset ()
    {
            parser.reset (self)
            resetToInitialState ()
    }
            
    //
    // ESC >
    //   DEC mnemonic: DECKPNM (https://vt100.net/docs/vt510-rm/DECKPNM.html)
    //   Enables the keypad to send numeric characters to the host.
    //
    func cmdKeypadNumericMode ()
    {
            applicationKeypad = false
            syncScrollArea ()
    }
                    
    //
    // ESC =
    //   DEC mnemonic: DECKPAM (https://vt100.net/docs/vt510-rm/DECKPAM.html)
    //   Enables the numeric keypad to send application sequences to the host.
    //
    func cmdKeypadApplicationMode ()
    {
            applicationKeypad = true
            syncScrollArea ()
    }

    func eraseAttr () -> Attribute
    {
        currentEraseAttribute
    }
    
    func setgCharset (_ v: UInt8, charset: [UInt8: String]?)
    {
        let index = Int(v)
        if index >= gCharsets.count {
            return
        }
        gCharsets[index] = charset
        if gLevel == v {
            self.charset = charset
        }
    }
    
    public func resize (cols: Int, rows: Int)
    {
        let newCols = max (cols, MINIMUM_COLS)
        let newRows = max (rows, MINIMUM_ROWS)
        if newCols == self.cols && newRows == self.rows {
            return
        }
        endSynchronizedOutput ()
        let oldCols = self.cols
        resizeBuffers(newColumns: newCols, newRows: newRows)
        self._cols = newCols
        self._rows = newRows
        options.cols = newCols
        options.rows = newRows
        if normalBuffer.cols == newCols {
            normalBuffer.setupTabStops(index: oldCols, tabStopWidth: tabStopWidth)
        }
        altBuffer.setupTabStops (index: oldCols, tabStopWidth: tabStopWidth)
        refresh (startRow: 0, endRow: self.rows - 1)
    }

    /**
     * Changes the scrollback size of the terminal after it has been instantiated.
     * The new scrollback size only affects the normal buffer, not the alternate buffer.
     *
     * - Parameter newScrollback: The new scrollback size in lines. Pass `nil` to disable scrollback.
     */
    /// Discards the scrollback history (the lines scrolled off the top of the
    /// visible screen) without clearing the visible screen or changing the
    /// configured scrollback capacity
    public func clearScrollback ()
    {
        // Only the normal buffer has scrollback
        normalBuffer.clearScrollback ()
        refresh (startRow: 0, endRow: self.rows - 1)
    }

    public func changeScrollback (_ newScrollback: Int?)
    {
        // Only the normal buffer has scrollback, the alt buffer should never have scrollback.
        normalBuffer.changeHistorySize(newScrollback)

        // Update the options to reflect the new scrollback size.
        options.scrollback = newScrollback ?? 0

        // Refresh the display to ensure proper rendering after scrollback size change.
        refresh (startRow: 0, endRow: self.rows - 1)
    }

    /**
     * Changes the scrollback (history) size of the terminal after it has been instantiated.
     * The new scrollback size only affects the normal buffer, not the alternate buffer.
     *
     * - Parameter newScrollback: The new scrollback size in lines. Pass `nil` to disable scrollback.
     */
    public func changeHistorySize (_ newScrollback: Int?)
    {
        changeScrollback(newScrollback)
    }
    
    func syncScrollArea ()
    {
        // This should call the viewport sync-scroll-area
    }

    // Mirrors ghostty: flip a flag and arm a safety timer. The view layer pauses
    // rendering while the flag is set (see updateDisplay's early-return). The
    // live buffer is mutated normally; no snapshot is taken.
    private func beginSynchronizedOutput ()
    {
        let wasActive = synchronizedOutputActive
        synchronizedOutputActive = true
        scheduleSynchronizedOutputTimeout()
        if !wasActive {
            tdel?.synchronizedOutputChanged(source: self, active: true)
        }
    }

    private func endSynchronizedOutput ()
    {
        guard synchronizedOutputActive else {
            return
        }
        synchronizedOutputActive = false
        synchronizedOutputTimeoutItem?.cancel()
        synchronizedOutputTimeoutItem = nil
        refresh (startRow: 0, endRow: rows - 1)
        tdel?.synchronizedOutputChanged(source: self, active: false)
    }

    private func scheduleSynchronizedOutputTimeout ()
    {
        synchronizedOutputTimeoutItem?.cancel()
        // Captures `self` strongly, on purpose. `[weak self]` here would be the
        // only remaining weak reference to a Terminal, and one is enough to move
        // it onto the runtime's side-table refcount path for life — roughly 9x
        // on every retain and release, paid by the parse loop, to protect a
        // timer that fires at most once per synchronized-output window.
        //
        // The cost of the strong capture is bounded and benign: libdispatch
        // releases the block once the item runs or its deadline passes, so a
        // Terminal abandoned with a timeout pending outlives its last external
        // reference by at most `synchronizedOutputTimeoutSeconds` (1 s). Unlike
        // any unowned scheme, this cannot race teardown.
        // See Docs/io-cpu-profile.md §3.1.
        let workItem = DispatchWorkItem {
            self.terminalLock.withLock {
                guard self.synchronizedOutputActive else {
                    return
                }
                self.endSynchronizedOutput()
            }
        }
        synchronizedOutputTimeoutItem = workItem
        // Not the main queue: this is the valve that unfreezes a display an
        // application left frozen with DECSET 2026, and the main thread is the
        // one most likely to be stuck when it is needed (io-gaps.md G5c). The
        // handler already takes the terminal lock, so it is safe anywhere.
        IOTimerQueue.shared.asyncAfter(deadline: .now() + synchronizedOutputTimeoutSeconds,
                                       execute: workItem)
    }

    func setViewYDisp (_ newValue: Int)
    {
        buffer.yDisp = newValue
    }

    /**
     * Registers that the region between startRow and endRow was modified and needs to be updated by the
     */
    public func refresh (startRow: Int, endRow: Int)
    {
        // TO BE HONEST - This probably should not be called directly,
        // instead the view shoudl after feeding data, determine if there is a need
        // to refresh based on the parameters provided for refresh ranges, and then
        // update, to avoid the backend rtiggering this multiple times.

        updateRange (startLine: startRow, endLine: endRow)
    }
    
    public func showCursor ()
    {
        if cursorHidden == false {
            return
        }
        cursorHidden = false
        //refresh (startRow: buffer.y, endRow: buffer.y)
        tdel?.showCursor (source: self)
    }
    
    public func hideCursor ()
    {
        if cursorHidden {
            return
        }
        cursorHidden = true
        tdel?.hideCursor(source: self)
    }

    // Encode button and position to characters
    func encodeMouseUtf (data: inout [UInt8], ch: Int)
    {
        if ch == 2047 {
            data.append(0)
            return
        }
        if ch < 127 {
            data.append (UInt8(ch))
        } else {
            let rc = ch > 2047 ? 2047 : ch
            data.append (0xc0 | (UInt8 (rc >> 6)))
            data.append (0x80 | (UInt8 (rc & 0x3f)))
        }
    }
    
    // XTSHIFTESCAPE (CSI > Ps s)
    func cmdSetShiftEscape (_ pars: [Int]) {
        let ps = pars.isEmpty ? 0 : pars[0]
        switch ps {
        case 0:
            mouseShiftCapture = false
        case 1:
            mouseShiftCapture = true
        default:
            break
        }
    }

    /**
     * Encodes the button action in the format expected by the client
     * - Parameter button: The button to encode
     * - Parameter release: `true` if this is a mouse release event
     * - Parameter shift: `true` if the shift key is pressed
     * - Parameter meta: `true` if the meta/alt key is pressed
     * - Parameter control: `true` if the control key is pressed
     * - Returns: the encoded value
     */
    public func encodeButton (button: Int, release: Bool, shift: Bool, meta: Bool, control: Bool) -> Int
    {
        var value: Int

        if release {
            value = 3
        } else {
            switch (button) {
            case 0:
                value = 0
            case 1:
                value = 1
            case 2:
                value = 2
            case 4:
                value = 64
            case 5:
                value = 65
            default:
                value = 0
            }
        }
        if mouseMode.sendsModifiers() {
            if shift {
                value |= 4
            }
            if meta {
                value |= 8
            }
            if control {
                value |= 16
            }
        }
        return value
    }
    
    public func sendEvent (buttonFlags: Int, x: Int, y: Int) {
      sendEvent(buttonFlags: buttonFlags, x: x, y: y, pixelX: x, pixelY: y)
    }
    
    /**
     * Sends a mouse event for a specific button at the specific location
     * - Parameter buttonFlags: Button flags encoded in Cb mode.
     * - Parameter x: X coordinate for the event
     * - Parameter y: Y coordinate for the event
     */
    public func sendEvent (buttonFlags: Int, x: Int, y: Int, pixelX: Int, pixelY: Int)
    {
        //print ("got \(mouseProtocol)")
        switch mouseProtocol {
        case .x10:
            sendResponse(cc.CSI, "M", [UInt8(min(buttonFlags+32, 255)), UInt8(min(32 + x+1, 255)), UInt8(min(32+y+1, 255))])
        case .sgr:
            let isRelease = (buttonFlags & 3) == 3 && (buttonFlags & 32) == 0
            let bflags : Int = isRelease ? (buttonFlags & ~3) : buttonFlags
            let m = isRelease ? "m" : "M"
            sendResponse(cc.CSI, "<\(bflags);\(x+1);\(y+1)\(m)")
        case .sgrPixel:
            let isRelease = (buttonFlags & 3) == 3 && (buttonFlags & 32) == 0
            let bflags : Int = isRelease ? (buttonFlags & ~3) : buttonFlags
            let m = isRelease ? "m" : "M"
            sendResponse(cc.CSI, "<\(bflags);\(pixelX);\(pixelY)\(m)")
            
        case .urxvt:
            sendResponse(cc.CSI, "\(buttonFlags+32);\(x+1);\(y+1)M");
        case .utf8:
            var buffer: [UInt8] = [UInt8 (ascii: "M")]
            encodeMouseUtf(data: &buffer, ch: buttonFlags+32)
            encodeMouseUtf (data: &buffer, ch: x+33)
            encodeMouseUtf (data: &buffer, ch: y+33)
            sendResponse(cc.CSI, buffer)
        }
    }
    
    /**
     * Sends a mouse motion event for a specific button at the specific location
     * - Parameter buttonFlags: Button flags encoded in Cb mode.
     * - Parameter x: X coordinate for the event
     * - Parameter y: Y coordinate for the event
     */
    public func sendMotion (buttonFlags: Int, x: Int, y: Int, pixelX: Int, pixelY: Int)
    {
        sendEvent(buttonFlags: buttonFlags+32, x: x, y: y, pixelX: pixelX, pixelY: pixelY)
    }
    
    static let matchColorCache : [Int:Int] = [:]
    func matchColor (_ r1: Int, _ g1: Int, _ b1: Int) -> Int32
    {
        // TODO
        abort ()
    }
    
    var terminalTitle: String = ""              // The Xterm terminal title
    var iconTitle: String = ""                  // The Xterm minimized window title
    var terminalTitleStack: [String] = []
    var terminalIconStack: [String] = []
    
    public func setTitle (text: String)
    {
        terminalTitle = text
        tdel?.setTerminalTitle(source: self, title: text)
    }

    public func setIconTitle (text: String)
    {
        iconTitle = text
        tdel?.setTerminalIconTitle(source: self, title: text)
    }

    func reverseIndex ()
    {
        let buffer = self.buffer
        restrictCursor()

        // When left/right margins are active, only scroll if cursor is within margins
        let canScroll = !marginMode || (buffer.x >= buffer.marginLeft && buffer.x <= buffer.marginRight)
        

        if buffer.y == buffer.scrollTop {
            if canScroll {
                // possibly move the code below to term.reverseScroll()
                // test: echo -ne '\e[1;1H\e[44m\eM\e[0m'
                // blankLine(true) is xterm/linux behavior
                let topRow = buffer.yBase + buffer.scrollTop
                let bottomRow = buffer.yBase + buffer.scrollBottom

                // Ensure the start index is within bounds to prevent crash (issue #256)
                // This can happen when the buffer has been trimmed and yBase is stale
                guard topRow < buffer.lines.count else {
                    print ("reverseIndex: start index \(topRow) >= lines.count \(buffer.lines.count), state: y=\(buffer.y) yBase=\(buffer.yBase) scrollTop=\(buffer.scrollTop) scrollBottom=\(buffer.scrollBottom) isAlternate=\(isCurrentBufferAlternate)")
                    return
                }

                let hasNarrowMargins = marginMode && (buffer.marginLeft > 0 || buffer.marginRight < cols - 1)

                if hasNarrowMargins {
                    // Do in-place reverse scrolling within margin columns only
                    let scrollRegionHeight = bottomRow - topRow + 1
                    let columnCount = buffer.marginRight - buffer.marginLeft + 1
                    let eraseBlank = currentEraseBlankCell

                    // Shift content down within the margin columns (reverse of scroll)
                    for i in stride(from: scrollRegionHeight - 1, through: 1, by: -1) {
                        let src = buffer.lines[topRow + i - 1]
                        let dst = buffer.lines[topRow + i]
                        dst.copyFrom(src, srcCol: buffer.marginLeft, dstCol: buffer.marginLeft, len: columnCount)
                        dst.isWrapped = false
                        buffer.clearImagesFromLine(at: topRow + i)
                        dst.renderMode = .single
                    }

                    // Clear the top row within the margin columns
                    let topLine = buffer.lines[topRow]
                    topLine.fill(with: eraseBlank,
                                 atCol: buffer.marginLeft, len: columnCount)
                    topLine.isWrapped = false
                    buffer.clearImagesFromLine(at: topRow)
                    topLine.renderMode = .single

                    selectionsInvalidateForColumnRestrictedScroll (top: topRow, bottom: bottomRow, left: buffer.marginLeft, right: buffer.marginRight)
                } else {
                    // Full-width scrolling - use original shiftElements approach
                    let scrollRegionHeight = buffer.scrollBottom - buffer.scrollTop
                    if !buffer.lines.shiftElements (start: topRow, count: scrollRegionHeight, offset: 1) {
                        print ("Assertion on reverseIndex, state was: y=\(buffer.y) scrollTop=\(buffer.scrollTop)  yDisp=\(buffer.yDisp) linesTop=\(buffer.linesTop) isAlternate=\(isCurrentBufferAlternate)")
                    }
                    buffer.lines[topRow] = buffer.getBlankLine(packedBlank: currentEraseBlankCell)

                    // Lines moved down in place; translate selections with them.
                    selectionsAdjustForInPlaceScroll (top: topRow, bottom: bottomRow, lines: -1)
                }
                if hasKittyPlacements {
                    scrollKittyPlacementsInMargins(
                        top: topRow,
                        bottom: bottomRow,
                        left: marginMode ? buffer.marginLeft : 0,
                        right: marginMode ? buffer.marginRight : cols - 1,
                        delta: 1)
                }
                refreshScrolledRegion(top: buffer.scrollTop, bottom: buffer.scrollBottom, canBlit: false)
            }
        } else if buffer.y > 0 {
            buffer.y -= 1
        }
    }
    
    /**
     * Provides a baseline set of environment variables that would be useful to run the terminal,
     * you can customzie these accordingly.
     * - Parameters:
     *  - termName: desired name for the terminal, if set to nil (the default), it sets it to xterm-256color
     *  - trueColor: if set to true, sets the COLORTERM variable to truecolor,
     * - Returns: an array of default environment variables that include TERM set to the specified value, or xterm-256color,
     * and if trueColor is true, COLORTERM=truecolor, the LANG=en_US.UTF-8 and it mirrors the currently set values
     * for LOGNAME, USER, DISPLAY, LC_TYPE, USER and HOME.
     */
    public static func getEnvironmentVariables (termName: String? = nil, trueColor: Bool = true) -> [String]
    {
        var l : [String] = []
        let t = termName == nil ? "xterm-256color" : termName!
        l.append ("TERM=\(t)")
        if trueColor {
            l.append ("COLORTERM=truecolor")
        }
        
        // Without this, tools like "vi" produce sequences that are not UTF-8 friendly
        l.append ("LANG=en_US.UTF-8")
        let env = ProcessInfo.processInfo.environment
        for x in ["LOGNAME", "USER", "DISPLAY", "LC_TYPE", "USER", "HOME" /* "PATH" */ ] {
            if env.keys.contains(x) {
                l.append ("\(x)=\(env[x]!)")
            }
        }
        return l
    }
    
    /// Specified the kind of buffer is being requested from the terminal
    public enum BufferKind: Sendable {
        /// The currently active buffer (can be either normal or alt)
        case active
        /// The normal buffer, regardless of which buffer is active
        case normal
        /// The alternate buffer, regardless of which buffer is active
        case alt
    }

    /// Location type for link lookup requests.
    public enum LinkLookupLocation: Sendable {
        /// Buffer coordinates (absolute row/col in the active display buffer).
        case buffer(Position)
        /// Screen coordinates (row/col relative to the visible viewport).
        case screen(Position)
    }

    /// Link lookup behavior for explicit hyperlinks and implicit detection.
    public enum LinkLookupMode: Sendable {
        /// Only look for explicit hyperlink payloads.
        case explicitOnly
        /// Look for explicit hyperlinks first, then fall back to implicit detection.
        case explicitAndImplicit
    }

    struct LinkMatch: Sendable {
        struct RowRange: Equatable, Sendable {
            let row: Int
            let range: Range<Int>
        }

        let text: String
        let row: Int
        let range: Range<Int>
        let isExplicit: Bool
        let rowRanges: [RowRange]
    }

    func bufferFromKind (kind: BufferKind) -> Buffer
    {
        switch kind {
        case .active:
            return buffer
        case .normal:
            return normalBuffer
        case .alt:
            return altBuffer
        }
    }
    
    /// Returns the contents of the specified terminal buffer encoded as UTF8 in the provided Data buffer
    /// - Parameter kind: which buffer to retrive the data for
    /// - Parameter encoding: which encoding to use for the returned value, defaults to utf8
    public func getBufferAsData (kind: BufferKind = .active, encoding: String.Encoding = .utf8) -> Data
    {
        var result = Data()
        
        let b = bufferFromKind(kind: kind)
        let newLine = Data([10])
        for row in 0..<b.lines.count {
            let bufferLine = b.lines [row]
            let str = bufferLine.translateToString(trimRight: true)
            if let encoded = str.data(using: encoding) {
                result.append (encoded)
                result.append (newLine)
            }
        }
        return result
    }
    
    /// Returns the text between the specified range
    ///
    public func getText (start: Position, end: Position) -> String
    {
        getText(start: start, end: end, buffer: buffer)
    }

    /// Returns a hyperlink or implicit link at the provided location.
    public func link(at location: LinkLookupLocation, mode: LinkLookupMode) -> String?
    {
        return linkMatch(at: location, mode: mode)?.text
    }

    func getDisplayText (start: Position, end: Position) -> String
    {
        getText(start: start, end: end, buffer: displayBuffer)
    }

    func linkMatch(at location: LinkLookupLocation, mode: LinkLookupMode) -> LinkMatch?
    {
        let buffer = displayBuffer
        guard let position = resolveLinkLocation(location, in: buffer) else {
            return nil
        }

        if let explicit = explicitLinkMatch(at: position, in: buffer) {
            return explicit
        }

        switch mode {
        case .explicitOnly:
            return nil
        case .explicitAndImplicit:
            return implicitLinkMatch(at: position, in: buffer)
        }
    }

    private func resolveLinkLocation(_ location: LinkLookupLocation, in buffer: Buffer) -> Position?
    {
        let pos: Position
        switch location {
        case .buffer(let position):
            pos = position
        case .screen(let position):
            pos = Position(col: position.col, row: position.row + buffer.yDisp)
        }

        if buffer.lines.isEmpty {
            return nil
        }
        let row = max(0, min(pos.row, buffer.lines.count - 1))
        let col = max(0, min(pos.col, cols - 1))
        return Position(col: col, row: row)
    }

    private func explicitLink(at position: Position, in buffer: Buffer) -> String?
    {
        let line = buffer.lines[position.row]
        guard let payload = line.packedView(at: position.col).getPayload() as? String else {
            return nil
        }
        return parseHyperlinkPayload(payload)
    }

    private func parseHyperlinkPayload(_ payload: String) -> String?
    {
        let split = payload.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard split.count > 1 else {
            return nil
        }
        return String(split[1])
    }

    private func explicitLinkMatch(at position: Position, in buffer: Buffer) -> LinkMatch?
    {
        guard let payloadToken = payloadCode(at: position, in: buffer) else {
            return nil
        }
        let line = buffer.lines[position.row]
        let lineLimit = min(cols, line.count)
        guard lineLimit > 0 else {
            return nil
        }
        var start = position.col
        while start > 0 && payloadCode(at: Position(col: start - 1, row: position.row), in: buffer) == payloadToken {
            start -= 1
        }
        var end = position.col
        while end < lineLimit && payloadCode(at: Position(col: end, row: position.row), in: buffer) == payloadToken {
            end += 1
        }
        guard start < end else {
            return nil
        }
        let rawPayload = line.packedView(at: position.col).getPayload() as? String
            ?? line.packedView(at: max(0, position.col - 1)).getPayload() as? String
        guard let payload = rawPayload, let url = parseHyperlinkPayload(payload) else {
            return nil
        }
        return LinkMatch(
            text: url,
            row: position.row,
            range: start..<end,
            isExplicit: true,
            rowRanges: [.init(row: position.row, range: start..<end)]
        )
    }

    private func implicitLinkMatch(at position: Position, in buffer: Buffer) -> LinkMatch?
    {
        guard let lineMap = buildGhosttyImplicitLineMap(at: position, in: buffer) else {
            return nil
        }
        guard let regex = Self.ghosttyImplicitLinkRegex else {
            return nil
        }

        let searchRange = NSRange(lineMap.text.startIndex..<lineMap.text.endIndex, in: lineMap.text)
        let matches = regex.matches(in: lineMap.text, options: [], range: searchRange)
        for match in matches {
            guard match.range.length > 0,
                  let textRange = Range(match.range, in: lineMap.text)
            else {
                continue
            }
            if suppressGhosttyLikeMatch(textRange, in: lineMap.text) {
                continue
            }

            let startOffset = lineMap.text.distance(from: lineMap.text.startIndex, to: textRange.lowerBound)
            let endOffset = lineMap.text.distance(from: lineMap.text.startIndex, to: textRange.upperBound)
            guard startOffset < lineMap.cells.count else {
                continue
            }
            let boundedEndOffset = min(endOffset, lineMap.cells.count)
            guard boundedEndOffset > startOffset else {
                continue
            }

            var containsTarget = false
            var rowStart: Int?
            var rowEnd: Int?
            var rowBounds: [Int: (start: Int, end: Int)] = [:]
            for idx in startOffset..<boundedEndOffset {
                let cell = lineMap.cells[idx]
                let cellEnd = cell.col + max(1, cell.width)

                if var bounds = rowBounds[cell.row] {
                    bounds.start = min(bounds.start, cell.col)
                    bounds.end = max(bounds.end, cellEnd)
                    rowBounds[cell.row] = bounds
                } else {
                    rowBounds[cell.row] = (start: cell.col, end: cellEnd)
                }

                if cell.row == lineMap.targetRow {
                    rowStart = min(rowStart ?? cell.col, cell.col)
                    rowEnd = max(rowEnd ?? cellEnd, cellEnd)
                    if lineMap.targetCol >= cell.col && lineMap.targetCol < cellEnd {
                        containsTarget = true
                    }
                }
            }
            guard containsTarget,
                  let rowStart,
                  let rowEnd,
                  rowStart < rowEnd
            else {
                continue
            }

            let rowRanges = rowBounds
                .keys
                .sorted()
                .compactMap { row -> LinkMatch.RowRange? in
                    guard let bounds = rowBounds[row], bounds.start < bounds.end else {
                        return nil
                    }
                    return .init(row: row, range: bounds.start..<bounds.end)
                }

            return LinkMatch(
                text: String(lineMap.text[textRange]),
                row: lineMap.targetRow,
                range: rowStart..<rowEnd,
                isExplicit: false,
                rowRanges: rowRanges
            )
        }
        return nil
    }

    private func payloadCode(at position: Position, in buffer: Buffer) -> UInt16?
    {
        guard position.row >= 0 && position.row < buffer.lines.count else {
            return nil
        }
        let line = buffer.lines[position.row]
        let lineLimit = min(cols, line.count)
        guard lineLimit > 0 else {
            return nil
        }
        let col = max(0, min(position.col, lineLimit - 1))
        let cell = line.packedCell(at: col)
        if cell.hasPayload {
            return cell.payloadCode
        }
        if line.packedCode(at: col) == 0 && col > 0 && line.packedWidth(at: col - 1) == 2 {
            let base = line.packedCell(at: col - 1)
            if base.hasPayload {
                return base.payloadCode
            }
        }
        return nil
    }

    private struct GhosttyImplicitCellRef: Sendable {
        let row: Int
        let col: Int
        let width: Int
    }

    private struct GhosttyImplicitLineMap: Sendable {
        let text: String
        let cells: [GhosttyImplicitCellRef]
        let targetRow: Int
        let targetCol: Int
    }

    private struct LinkRowEdgeInfo: Sendable {
        let firstCol: Int
        let firstChar: Character
        let lastCol: Int
        let lastChar: Character
    }

    // Ghostty-style URL/path pattern adapted for ICU regex.
    // Oniguruma uses a variable-length lookbehind in one branch; we keep
    // compatibility by applying an equivalent post-match suppression rule.
    private static let ghosttyImplicitLinkRegex: NSRegularExpression? = {
        let urlSchemes = #"https?://|mailto:|ftp://|file:|ssh:|git://|ssh://|tel:|magnet:|ipfs://|ipns://|gemini://|gopher://|news:"#
        // NOTE: this used to be `\[[:0-9a-fA-F]+(?:[:0-9a-fA-F]*)+\]`. That inner `(?:X*)+` is a
        // classic catastrophic-backtracking construct: on input that opens a bracket but never
        // closes it (e.g. `https://[aaaaaaaa...`), ICU explores exponentially many ways to split
        // the run before failing. Measured on the unmodified pattern: 33 chars -> 2.7s,
        // 37 chars -> 23s, 41 chars -> 297s, all on the main thread. The nested quantifier is
        // also redundant -- `X+(?:X*)+` accepts exactly the same language as `X+` -- so removing
        // it is behaviour-preserving. Same inputs now complete in under a millisecond.
        let ipv6URLPattern = #"(?:\[[:0-9a-fA-F]+\](?::[0-9]+)?)"#
        let schemeURLChars = #"[\w\-.~:/?#@!$&*+,;=%]"#
        let pathChars = #"[\w\-.~:\/?#@!$&*+;=%]"#
        let noTrailingPunctuation = #"(?<![,.])"#
        let noTrailingColon = #"(?<!:)"#
        let trailingSpacesAtEOL = #"(?: +(?= *$))?"#
        let dottedPathLookahead = #"(?=[\w\-.~:\/?#@!$&*+;=%]*\.)"#
        let nonDottedPathLookahead = #"(?![\w\-.~:\/?#@!$&*+;=%]*\.)"#
        let dottedPathSpaceSegments = #"(?:(?<!:) (?!\w+:\/\/)[\w\-.~:\/?#@!$&*+;=%]*[\/.])*"#
        let anyPathSpaceSegments = #"(?:(?<!:) (?!\w+:\/\/)[\w\-.~:\/?#@!$&*+;=%]+)*"#

        // The body used to be `(?:IPV6|CHARS+SUFFIX?)+`: a `+` nested directly inside a `+`, so a
        // run of N body characters could be split across iterations in exponentially many ways.
        // Normally ICU exits early, because `(?<![,.])` only rejects an end position whose
        // preceding character is `.` or `,` -- backing off one character succeeds. But when the
        // match ends in a *run* of `.`/`,` (a URL followed by an ellipsis, dot leaders, or empty
        // CSV fields) every end position fails and the full 2^N enumeration is forced:
        // `https://example.com/a/b/c` + 17 dots (42 chars) blocked the main thread for 1.4s, each
        // extra dot multiplying the time by ~2.6.
        //
        // Consuming one token per iteration removes the ambiguity entirely. A token is either an
        // IPv6 literal or one URL character with its optional bracketed suffix. This keeps a
        // suffix attached to a URL character and prevents an IPv6 literal with a port from
        // absorbing following bracketed text.
        let bracketedWordSuffix = #"(?:[\(\[]\w*[\)\]])"#
        let schemeURLToken =
            "(?:" + ipv6URLPattern + "|" +
            schemeURLChars + "(?:" + bracketedWordSuffix + ")?)"
        let schemeURLBranch =
            "(?:" + urlSchemes + ")" +
            schemeURLToken + "+" +
            noTrailingPunctuation

        let rootedOrRelativePathPrefix = #"(?:\.\.\/|\.\/|(?<!\w)~\/|(?:[\w][\w\-.]*\/)*(?<!\w)\$[A-Za-z_]\w*\/|\.[\w][\w\-.]*\/|(?<![\w~\/])\/(?!\/))"#
        let rootedOrRelativePathBranch =
            rootedOrRelativePathPrefix +
            "(?:" +
            dottedPathLookahead +
            pathChars + "+" +
            dottedPathSpaceSegments +
            noTrailingColon +
            trailingSpacesAtEOL +
            "|" +
            nonDottedPathLookahead +
            pathChars + "+" +
            anyPathSpaceSegments +
            noTrailingColon +
            trailingSpacesAtEOL +
            ")"

        // Ghostty uses (?<!\$\d*) here, which is unsupported by ICU.
        // We enforce the same intent by skipping any match preceded by '$'.
        let bareRelativePathPrefix = #"(?<!\w)[\w][\w\-.]*\/"#
        let bareRelativePathBranch =
            dottedPathLookahead +
            bareRelativePathPrefix +
            pathChars + "+" +
            dottedPathSpaceSegments +
            noTrailingColon +
            trailingSpacesAtEOL

        let regex = schemeURLBranch + "|" + rootedOrRelativePathBranch + "|" + bareRelativePathBranch
        return try? NSRegularExpression(pattern: regex, options: [])
    }()

    private static let ghosttyContinuationCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:/?#[]@!$&*+,;=%()"
    )

    private func buildGhosttyImplicitLineMap(at position: Position, in buffer: Buffer) -> GhosttyImplicitLineMap?
    {
        guard position.row >= 0 && position.row < buffer.lines.count else {
            return nil
        }

        let targetRow = position.row
        let targetLine = buffer.lines[targetRow]
        let targetRawLimit = min(cols, targetLine.count)
        guard targetRawLimit > 0 else {
            return nil
        }

        var targetCol = max(0, min(position.col, targetRawLimit - 1))
        if targetCol > 0 && targetLine.packedCode(at: targetCol) == 0 &&
            targetLine.packedWidth(at: targetCol - 1) == 2 {
            targetCol -= 1
        }

        var startRow = targetRow
        while startRow > 0 && buffer.lines[startRow].isWrapped {
            startRow -= 1
        }
        var endRow = targetRow
        while endRow + 1 < buffer.lines.count && buffer.lines[endRow + 1].isWrapped {
            endRow += 1
        }
        if startRow == targetRow && endRow == targetRow,
           let (heuristicStart, heuristicEnd) = heuristicImplicitGroup(around: targetRow, in: buffer)
        {
            startRow = heuristicStart
            endRow = heuristicEnd
        }

        var text = ""
        var cells: [GhosttyImplicitCellRef] = []
        cells.reserveCapacity((endRow - startRow + 1) * cols)
        var targetIsInsideTrimmedContent = false

        for row in startRow...endRow {
            let line = buffer.lines[row]
            let rawLimit = min(cols, line.count)
            if rawLimit <= 0 {
                continue
            }
            let lineLimit = min(rawLimit, line.getTrimmedLength())
            if lineLimit <= 0 {
                continue
            }
            let isContinuationRow = isImplicitContinuationRow(row, startRow: startRow, in: buffer)
            let startCol = isContinuationRow ? firstNonWhitespaceColumn(in: line, lineLimit: lineLimit) : 0
            guard startCol < lineLimit else {
                continue
            }
            if row == targetRow && targetCol >= startCol && targetCol < lineLimit {
                targetIsInsideTrimmedContent = true
            }

            for col in startCol..<lineLimit {
                if col > 0 && line.packedCode(at: col) == 0 &&
                    line.packedWidth(at: col - 1) == 2 {
                    continue
                }
                let cell = line.packedView(at: col)
                var character = cell.getCharacter()
                if character == "\u{0}" {
                    character = " "
                }
                text.append(character)
                cells.append(
                    GhosttyImplicitCellRef(
                        row: row,
                        col: col,
                        width: max(1, Int(cell.width))
                    )
                )
            }
        }

        guard !text.isEmpty, !cells.isEmpty, targetIsInsideTrimmedContent else {
            return nil
        }

        return GhosttyImplicitLineMap(
            text: text,
            cells: cells,
            targetRow: targetRow,
            targetCol: targetCol
        )
    }

    private func isImplicitContinuationRow(_ row: Int, startRow: Int, in buffer: Buffer) -> Bool
    {
        guard row > startRow else {
            return false
        }
        if buffer.lines[row].isWrapped {
            return true
        }
        return canJoinImplicitRows(upper: row - 1, lower: row, in: buffer)
    }

    private func heuristicImplicitGroup(around row: Int, in buffer: Buffer) -> (start: Int, end: Int)?
    {
        var start = row
        var end = row

        while start > 0 && canJoinImplicitRows(upper: start - 1, lower: start, in: buffer) {
            start -= 1
        }
        while end + 1 < buffer.lines.count && canJoinImplicitRows(upper: end, lower: end + 1, in: buffer) {
            end += 1
        }

        return (start == row && end == row) ? nil : (start, end)
    }

    private func canJoinImplicitRows(upper: Int, lower: Int, in buffer: Buffer) -> Bool
    {
        guard let upperInfo = linkRowEdgeInfo(row: upper, in: buffer),
              let lowerInfo = linkRowEdgeInfo(row: lower, in: buffer)
        else {
            return false
        }

        // Heuristic for editor-rendered wraps: the upper segment should reach
        // near the visual right edge and the seam should form a valid link.
        let continuationThreshold = max(0, cols - max(2, cols / 5))
        guard upperInfo.lastCol >= continuationThreshold else {
            return false
        }

        let upperScalars = upperInfo.lastChar.unicodeScalars
        let lowerScalars = lowerInfo.firstChar.unicodeScalars
        guard !upperScalars.isEmpty, !lowerScalars.isEmpty else {
            return false
        }
        guard upperScalars.allSatisfy({ Self.ghosttyContinuationCharacters.contains($0) }),
              lowerScalars.allSatisfy({ Self.ghosttyContinuationCharacters.contains($0) })
        else {
            return false
        }

        return seamContainsGhosttyImplicitLink(
            upper: upper,
            lower: lower,
            upperLastCol: upperInfo.lastCol,
            lowerFirstCol: lowerInfo.firstCol,
            in: buffer
        )
    }

    private func linkRowEdgeInfo(row: Int, in buffer: Buffer) -> LinkRowEdgeInfo?
    {
        guard row >= 0 && row < buffer.lines.count else {
            return nil
        }
        let line = buffer.lines[row]
        let rawLimit = min(cols, line.count)
        guard rawLimit > 0 else {
            return nil
        }
        let lineLimit = min(rawLimit, line.getTrimmedLength())
        guard lineLimit > 0 else {
            return nil
        }

        var first: (col: Int, char: Character)?
        var col = 0
        while col < lineLimit {
            if let ch = linkCharacterAt(line: line, col: col), !ch.isWhitespace {
                first = (col, ch)
                break
            }
            col += 1
        }
        guard let first else {
            return nil
        }

        var last: (col: Int, char: Character)?
        var rcol = lineLimit - 1
        while rcol >= first.col {
            if let ch = linkCharacterAt(line: line, col: rcol), !ch.isWhitespace {
                last = (rcol, ch)
                break
            }
            if rcol == 0 { break }
            rcol -= 1
        }
        guard let last else {
            return nil
        }

        return LinkRowEdgeInfo(
            firstCol: first.col,
            firstChar: first.char,
            lastCol: last.col,
            lastChar: last.char
        )
    }

    private func seamContainsGhosttyImplicitLink(
        upper: Int,
        lower: Int,
        upperLastCol: Int,
        lowerFirstCol: Int,
        in buffer: Buffer
    ) -> Bool
    {
        guard let regex = Self.ghosttyImplicitLinkRegex else {
            return false
        }
        guard upper >= 0, upper < buffer.lines.count, lower >= 0, lower < buffer.lines.count else {
            return false
        }

        let upperLine = buffer.lines[upper]
        let upperLimit = min(min(cols, upperLine.count), upperLastCol + 1)
        guard upperLimit > 0 else {
            return false
        }
        let upperStart = max(0, upperLimit - 96)
        let upperText = implicitLineSegmentText(line: upperLine, startCol: upperStart, endCol: upperLimit)
        guard !upperText.isEmpty else {
            return false
        }

        let lowerLine = buffer.lines[lower]
        let lowerLimit = min(min(cols, lowerLine.count), lowerLine.getTrimmedLength())
        guard lowerFirstCol < lowerLimit else {
            return false
        }
        let lowerEnd = min(lowerLimit, lowerFirstCol + 96)
        let lowerText = implicitLineSegmentText(line: lowerLine, startCol: lowerFirstCol, endCol: lowerEnd)
        guard !lowerText.isEmpty else {
            return false
        }

        let candidate = upperText + lowerText
        let seamOffset = upperText.utf16.count
        let searchRange = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        for match in regex.matches(in: candidate, options: [], range: searchRange) {
            let matchStart = match.range.location
            let matchEnd = match.range.location + match.range.length
            guard matchStart < seamOffset, matchEnd > seamOffset else {
                continue
            }
            guard let textRange = Range(match.range, in: candidate) else {
                continue
            }
            if suppressGhosttyLikeMatch(textRange, in: candidate) {
                continue
            }
            return true
        }

        return false
    }

    private func implicitLineSegmentText(line: BufferLine, startCol: Int, endCol: Int) -> String
    {
        let boundedStart = max(0, startCol)
        let boundedEnd = min(line.count, endCol)
        guard boundedStart < boundedEnd else {
            return ""
        }

        var result = ""
        result.reserveCapacity(boundedEnd - boundedStart)
        for col in boundedStart..<boundedEnd {
            if col > 0 && line.packedCode(at: col) == 0 &&
                line.packedWidth(at: col - 1) == 2 {
                continue
            }
            var character = line.packedCharacter(at: col)
            if character == "\u{0}" {
                character = " "
            }
            result.append(character)
        }
        return result
    }

    private func linkCharacterAt(line: BufferLine, col: Int) -> Character?
    {
        guard col >= 0 && col < line.count else {
            return nil
        }
        let cell = line.packedView(at: col)
        if cell.code != 0 {
            return cell.getCharacter()
        }
        if col > 0 && line.packedWidth(at: col - 1) == 2 {
            let base = line.packedView(at: col - 1)
            if base.code != 0 {
                return base.getCharacter()
            }
        }
        return nil
    }

    private func firstNonWhitespaceColumn(in line: BufferLine, lineLimit: Int) -> Int
    {
        guard lineLimit > 0 else {
            return 0
        }
        var col = 0
        while col < lineLimit {
            let cell = line.packedView(at: col)
            if cell.code != 0 {
                if !cell.getCharacter().isWhitespace {
                    return col
                }
            } else if col > 0 && line.packedWidth(at: col - 1) == 2 {
                let base = line.packedView(at: col - 1)
                if base.code != 0 && !base.getCharacter().isWhitespace {
                    return col
                }
            }
            col += 1
        }
        return lineLimit
    }

    private func suppressGhosttyLikeMatch(_ range: Range<String.Index>, in text: String) -> Bool
    {
        guard range.lowerBound > text.startIndex else {
            return false
        }
        return text[text.index(before: range.lowerBound)] == "$"
    }

    func getText (start: Position, end: Position, buffer: Buffer) -> String
    {
        let lines = getSelectedLines(p1: start, p2: end, buffer: buffer)
        if lines.count == 0 {
            return ""
        }
        var r = ""
        for line in lines {
            r += line.toString()
        }
        return r
    }

    // This version validates the input parameters
    func getSelectedLines(p1: Position, p2: Position, buffer: Buffer) -> [Line]
    {
        var start = p1
        var end = p2
        let b = buffer
        
        switch Position.compare (start, end) {
        case .equal:
            return []
        case .after:
            let tmp = start
            start = end
            end = tmp
        case .before:
            break
        }
        if start.row < 0 || start.row > b.lines.count {
            return []
        }
        
        if end.row >= b.lines.count {
            end.row = b.lines.count-1
        }
        return _getSelectedLines(start, end, buffer: buffer)
    }
    
    func _getSelectedLines(_ start: Position, _ end: Position, buffer: Buffer) -> [Line]
    {
        var lines: [Line] = []
        let buf = buffer
        var str = ""
        var currentLine = Line ()
        lines.append(currentLine)
        
        // keep a list of blank lines that we see. if we see content after a group
        // of blanks, add those blanks but skip all remaining / trailing blanks
        // these will be blank lines in the selected text output
        var blanks: [LineFragment] = []
        
        func addBlanks () {
            var lastLine = -1;
            for b in blanks {
                if lastLine != -1 && b.line != lastLine {
                    currentLine = Line ()
                    lines.append(currentLine)
                }
                
                lastLine = b.line
                currentLine.add(fragment: b)
            }
            blanks = []
        };
        
        // get the first line
        var bufferLine = buf.lines [start.row]
        if bufferLine.hasAnyContent() {
            let str: String = translateBufferLineToString (buffer: buf, line: start.row, start: start.col, end: start.row < end.row ? -1 : end.col)
            
            let fragment = LineFragment (text: str, line: start.row, location: start.col, length: str.count)
            currentLine.add (fragment: fragment)
        }
        
        // get the middle rows
        var line = start.row + 1
        var isWrapped = false
        while line < end.row {
            bufferLine = buffer.lines [line]
            isWrapped = bufferLine.isWrapped
            
            str = translateBufferLineToString (buffer: buf, line: line, start: 0, end: -1)
            
            if bufferLine.hasAnyContent () {
                // add previously gathered blank fragments
                addBlanks ()
                
                if !isWrapped {
                    // this line is not a wrapped line, so the
                    // prior line has a hard linefeed
                    // add a fragment to that line
                    currentLine.add (fragment: LineFragment.newLine (line: line - 1))
                    
                    // start a new line
                    currentLine = Line ()
                    lines.append(currentLine)
                }
                
                // add the text we found to the current line
                currentLine.add (fragment: LineFragment (text: str, line: line, location: 0, length: str.count))
            } else {
                // this line has no content, which means that it's a blank line inserted
                // somehow, or one of the trailing blank lines after the last actual content
                // make a note of the line
                // check that this line is a wrapped line, if so, add a line feed fragment
                if !isWrapped {
                    blanks.append (LineFragment.newLine (line: line - 1))
                }
                
                blanks.append(LineFragment (text: str, line: line, location: 0, length: str.count))
            }
            
            line += 1
        }
        
        // get the last row
        if end.row != start.row {
            bufferLine = buffer.lines [end.row]
            if bufferLine.hasAnyContent () {
                addBlanks ()
                
                isWrapped = bufferLine.isWrapped
                str = translateBufferLineToString (buffer: buf, line: end.row, start: 0, end: end.col)
                if !isWrapped {
                    currentLine.add(fragment: LineFragment.newLine (line: line - 1))
                    currentLine = Line ()
                    lines.append(currentLine)
                }
                
                currentLine.add (fragment: LineFragment (text: str, line: line, location: 0, length: str.count))
            }
        }
        return lines
    }
    
    func translateBufferLineToString (buffer: Buffer, line: Int, start: Int, end: Int) -> String
    {
        buffer.translateBufferLineToString(lineIndex: line, trimRight: true, startCol: start, endCol: end, skipNullCellsFollowingWide: true, characterProvider: { self.getCharacter(for: $0) }).replacingOccurrences(of: "\u{0}", with: " ")
    }
}

/// Terminal used by the built-in owners. These owners prepare their state once
/// before each feed, so a line-feed callback for each parsed line is redundant.
final class ManagedFeedTerminal: Terminal {
    private var managedFeedDepth = 0

    @inline(__always)
    override func withManagedFeed<T> (_ body: () throws -> T) rethrows -> T
    {
        managedFeedDepth += 1
        defer { managedFeedDepth -= 1 }
        return try body()
    }

    @inline(__always)
    override public func emitLineFeed ()
    {
        guard managedFeedDepth == 0 else { return }
        emitUnmanagedLineFeed()
    }

    @inline(never)
    private func emitUnmanagedLineFeed ()
    {
        super.emitLineFeed()
    }
}

// Default implementations
public extension TerminalDelegate {
    func cursorStyleChanged (source: Terminal, newStyle: CursorStyle)
    {
        // Do nothing
    }
    
    func setTerminalTitle (source: Terminal, title: String) {
        // Do nothing
    }

    func setTerminalIconTitle (source: Terminal, title: String) {
        // nothing
    }
    
    func scrolled(source: Terminal, yDisp: Int) {
        // nothing
    }
    
    func linefeed(source: Terminal) {
        // nothing
    }
    
    func bufferActivated(source: Terminal) {
        // nothing
    }

    func synchronizedOutputChanged(source: Terminal, active: Bool) {
        // nothing
    }
    
    func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? {
        // no special handling
        return nil
    }
    
    func sizeChanged(source: Terminal) {
        // nothing
    }
    
    func bell (source: Terminal){
        // nothing
    }
    
    func isProcessTrusted (source: Terminal) -> Bool {
        return true
    }
    
    func selectionChanged (source: Terminal){
        // nothing
    }
    
    func showCursor(source: Terminal) {
        // nothing
    }

    func hideCursor(source: Terminal) {
        // nothing
    }

    func mouseModeChanged(source: Terminal) {
    }

    func cellSizeInPixels(source: Terminal) -> (width: Int, height: Int)? {
        return nil
    }
    
    func hostCurrentDirectoryUpdated (source: Terminal) {
    }
    
    func hostCurrentDocumentUpdated (source: Terminal) {
    }
    
    func colorChanged (source: Terminal, idx: Int?) {
        
    }
    
    func getColors (source: Terminal) -> (foreground: Color, background: Color)
    {
        return (source.foregroundColor, source.backgroundColor)
    }
    
    func setForegroundColor (source: Terminal, color: Color)
    {
        source.foregroundColor = color
    }
    
    func setBackgroundColor (source: Terminal, color: Color)
    {
        source.backgroundColor = color
    }
    
    func setCursorColor (source: Terminal, color: Color?)
    {
        source.cursorColor = color
    }
    
    func iTermContent (source: Terminal, content: ArraySlice<UInt8>) {
    }
    
    func clipboardCopy(source: Terminal, content: Data) {
    }
    
    func clipboardRead(source: Terminal) -> Data? {
        return nil
    }
    
    func notify(source: Terminal, title: String, body: String) {
    }

    func progressReport(source: Terminal, report: Terminal.ProgressReport) {
    }
    
    func createImageFromBitmap (source: Terminal, bytes: inout [UInt8], width: Int, height: Int){
    }

    func createImage (source: Terminal, data: Data, width: ImageSizeRequest, height: ImageSizeRequest, preserveAspectRatio: Bool) {
    }    
}
