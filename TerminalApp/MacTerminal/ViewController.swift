//
//  ViewController.swift
//  MacTerminal
//
//  Created by Miguel de Icaza on 3/11/20.
//  Copyright © 2020 Miguel de Icaza. All rights reserved.
//

import Cocoa
import SwiftTerm
import UniformTypeIdentifiers
class ViewController: NSViewController, LocalProcessTerminalViewDelegate, NSUserInterfaceValidations {
    @IBOutlet var loggingMenuItem: NSMenuItem?

    private struct ReverseVideoTestState {
        let foregroundColor: NSColor
        let backgroundColor: NSColor
        let windowIsOpaque: Bool
        let windowBackgroundColor: NSColor
    }

    private var reverseVideoTestState: ReverseVideoTestState?

    var changingSize = false
    var logging: Bool = false
    var zoomGesture: NSMagnificationGestureRecognizer?
    var postedTitle: String = ""
    var postedDirectory: String? = nil
    
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        if changingSize {
            return
        }
        guard let window = view.window else { return }
        var newFrame = terminal.getOptimalFrameSize ()
        let windowFrame = window.frame
        newFrame = CGRect (x: windowFrame.minX, y: windowFrame.minY, width: newFrame.width, height: windowFrame.height - view.frame.height + newFrame.height)

        // Two changes from the obvious version, both measured on the
        // resize-under-flood case (Docs/io-baselines.md, G5b):
        //
        // 1. **No animation.** Animating the snap-to-cell-size makes AppKit
        //    emit a stream of intermediate frames, each of which resizes the
        //    terminal and calls back here. Main-thread stall p99 over a resize
        //    churn: 14–35 ms animated against 6–17 ms not. It is also the
        //    reason SwiftTerm cannot coalesce resizes outside a live drag —
        //    with the animation gone, coalescing every frame change costs
        //    nothing (6.45–15.32 ms), and with it the same change costs
        //    188–216 ms.
        // 2. **Idempotent rather than re-entrant.** `changingSize` only stops
        //    the loop when the frame change re-enters this method inside the
        //    same call stack. Comparing against the frame we already have
        //    stops it either way, including when the callback arrives a frame
        //    later, and costs nothing.
        let epsilon: CGFloat = 0.5
        if abs(newFrame.width - windowFrame.width) < epsilon,
           abs(newFrame.height - windowFrame.height) < epsilon {
            return
        }

        changingSize = true
        window.setFrame(newFrame, display: true, animate: false)
        changingSize = false
    }
    
    func updateWindowTitle ()
    {
        var newTitle: String
        if let dir = postedDirectory {
            if let uri = URL(string: dir) {
                if postedTitle == "" {
                    newTitle = uri.path
                } else {
                    newTitle = "\(postedTitle) - \(uri.path)"
                }
            } else {
                newTitle = postedTitle
            }
        } else {
            newTitle = postedTitle
        }
        view.window?.title = newTitle
    }
    
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        postedTitle = title
        updateWindowTitle ()
    }
    
    func hostCurrentDirectoryUpdate (source: TerminalView, directory: String?) {
        self.postedDirectory = directory
        updateWindowTitle()
    }
    
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        view.window?.close()
        if let e = exitCode {
            print ("Process terminated with code: \(e)")
        } else {
            print ("Process vanished")
        }
    }
    var terminal: LocalProcessTerminalView!
    var baselineHarness: IOBaselineHarness?

    static weak var lastTerminal: LocalProcessTerminalView!
    
    func getBufferAsData () -> Data
    {
        return terminal.getTerminal().getBufferAsData ()
    }
    
    func updateLogging ()
    {
//        let path = logging ? "/Users/miguel/Downloads/Logs" : nil
//        terminal.setHostLogging (directory: path)
        NSUserDefaultsController.shared.defaults.set (logging, forKey: "LogHostOutput")
    }
    
    // Returns the shell associated with the current account
    func getShell () -> String
    {
        let bufsize = sysconf(_SC_GETPW_R_SIZE_MAX)
        guard bufsize != -1 else {
            return "/bin/bash"
        }
        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: bufsize)
        defer {
            buffer.deallocate()
        }
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>? = UnsafeMutablePointer<passwd>.allocate(capacity: 1)
        
        if getpwuid_r(getuid(), &pwd, buffer, bufsize, &result) != 0 {
            return "/bin/bash"
        }
        return String (cString: pwd.pw_shell)
    }
    
    class TD: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {
        }
        
        
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        terminal = LocalProcessTerminalView(frame: view.frame)
        terminal.bellStyle = .none
        // Overridable for measurement: SWIFTTERM_BUFFERING=perRowPersistent
        terminal.metalBufferingMode =
            ProcessInfo.processInfo.environment["SWIFTTERM_BUFFERING"] == "perRowPersistent"
            ? .perRowPersistent : .perFrameAggregated
        // Metal is on by default so ordinary use exercises the render loop
        // (io-gaps.md WO-F5). Baselines still need both paths — G1's
        // before-picture is the Core Graphics one — so the switch is
        // three-way: SWIFTTERM_METAL=0 forces the CPU renderer, =1 or --metal
        // forces the GPU one, and unset means on.
        let metalSetting = ProcessInfo.processInfo.environment["SWIFTTERM_METAL"]
        let useMetal = ProcessInfo.processInfo.arguments.contains("--metal")
            || (metalSetting != "0")
        do {
            try terminal.setUseMetal(useMetal)
        } catch {
            print("METAL UNAVAILABLE: \(error)")
        }
        let defaultForegroundColor = NSColor(
            calibratedRed: 1.0,
            green: 1.0,
            blue: 1.0,
            alpha: 1.0
        )
        let defaultBackgroundColor = NSColor(
            calibratedRed: CGFloat(0x28) / 255.0,
            green: CGFloat(0x2c) / 255.0,
            blue: CGFloat(0x34) / 255.0,
            alpha: 1.0
        )
        terminal.nativeForegroundColor = defaultForegroundColor
        terminal.nativeBackgroundColor = defaultBackgroundColor
        terminal.layer?.backgroundColor = defaultBackgroundColor.cgColor
        terminal.caretColor = .systemGreen
        terminal.getTerminal().setCursorStyle(.steadyBlock)
        zoomGesture = NSMagnificationGestureRecognizer(target: self, action: #selector(zoomGestureHandler))
        terminal.addGestureRecognizer(zoomGesture!)
        ViewController.lastTerminal = terminal
        terminal.processDelegate = self
        terminal.feed(text: "Welcome to SwiftTerm")

        let shell = getShell()
        let shellIdiom = "-" + NSString(string: shell).lastPathComponent
        
        FileManager.default.changeCurrentDirectoryPath (FileManager.default.homeDirectoryForCurrentUser.path)
        terminal.startProcess (executable: shell, execName: shellIdiom)
        view.addSubview(terminal)
        logging = NSUserDefaultsController.shared.defaults.bool(forKey: "LogHostOutput")
        updateLogging ()

        // Support --cmd "command" launch argument for automation/profiling
        let args = ProcessInfo.processInfo.arguments
        // Same one-window rule as the baselines: two restored documents would
        // otherwise both type the command and both run the load.
        if let idx = args.firstIndex(of: "--cmd"), idx + 1 < args.count,
           !ViewController.commandClaimed {
            ViewController.commandClaimed = true
            let command = args[idx + 1]
            // Wait for the shell to print its prompt rather than typing after a
            // fixed delay: a command sent before the shell is listening is
            // simply lost, which shows up as a window that opens and does
            // nothing. Detected the same way the baseline harness does it —
            // the byte counter going quiet.
            sendWhenShellIsReady(command)
        }

        startBaselineFromLaunchArguments()

        #if DEBUG_MOUSE_FOCUS
        var t = NSTextField(frame: NSRect (x: 0, y: 100, width: 200, height: 30))
        t.backgroundColor = NSColor.white
        t.stringValue = "Hello - here to test focus switching"
        
        view.addSubview(t)
        #endif
    }
    
    override func viewWillDisappear() {
        //terminal = nil
    }
    
    @objc
    func zoomGestureHandler (_ sender: NSMagnificationGestureRecognizer) {
        if sender.magnification > 0 {
            biggerFont (sender)
        } else {
            smallerFont(sender)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        changingSize = true
        terminal.frame = view.frame
        changingSize = false
        terminal.needsLayout = true
    }

    @objc @IBAction
    func toggleReverseVideoTest(_ source: AnyObject)
    {
        if let savedState = reverseVideoTestState {
            terminal.nativeForegroundColor = savedState.foregroundColor
            terminal.nativeBackgroundColor = savedState.backgroundColor
            view.window?.isOpaque = savedState.windowIsOpaque
            view.window?.backgroundColor = savedState.windowBackgroundColor
            reverseVideoTestState = nil
            terminal.feed(text: "\u{1b}[0m\r\nReverse-video test ended.\r\n")
            return
        }

        guard let window = view.window else {
            return
        }

        reverseVideoTestState = ReverseVideoTestState(
            foregroundColor: terminal.nativeForegroundColor,
            backgroundColor: terminal.nativeBackgroundColor,
            windowIsOpaque: window.isOpaque,
            windowBackgroundColor: window.backgroundColor)

        // This non-complementary pair makes RGB inversion visibly incorrect.
        terminal.nativeForegroundColor = NSColor(
            srgbRed: 0x93 / 255.0,
            green: 0xa1 / 255.0,
            blue: 0xa1 / 255.0,
            alpha: 1)
        terminal.nativeBackgroundColor = NSColor(
            srgbRed: 0x00 / 255.0,
            green: 0x2b / 255.0,
            blue: 0x36 / 255.0,
            alpha: 1)

        window.isOpaque = false
        window.backgroundColor = .clear
        terminal.backgroundOpacity = 0

        let escape = "\u{1b}"
        terminal.feed(text:
            "\(escape)[2J\(escape)[H" +
            "Reverse-video transparency test\r\n" +
            "Default background opacity: 0%\r\n\r\n" +
            "\(escape)[0m Normal default text \r\n" +
            "\(escape)[7m Reversed default text \(escape)[27m  Expected: opaque light block, dark text\r\n" +
            "\(escape)[38;2;220;50;47m Red foreground \(escape)[7m Red/default reversed \(escape)[0m\r\n" +
            "\(escape)[48;2;38;139;210m Default foreground on blue \(escape)[7m Reversed \(escape)[0m\r\n\r\n" +
            "Before PR 623, the default reversed block disappears or uses inverted RGB.\r\n" +
            "With PR 623, the default colors swap and the reversed block stays opaque.\r\n")
    }


    @objc @IBAction
    func set80x25 (_ source: AnyObject)
    {
        terminal.resize(cols: 80, rows: 25)
    }

    var lowerCol = 80
    var lowerRow = 25
    var higherCol = 160
    var higherRow = 60
    
    func queueNextSize ()
    {
        // If they requested a stop
        if resizificating == 0 {
            return
        }
        var next = terminal.getTerminal().getDims ()
        if resizificating > 0 {
            if next.cols < higherCol {
                next.cols += 1
            }
            if next.rows < higherRow {
                next.rows += 1
            }
        } else {
            if next.cols > lowerCol {
                next.cols -= 1
            }
            if next.rows > lowerRow {
                next.rows -= 1
            }
        }
        terminal.resize (cols: next.cols, rows: next.rows)
        var direction = resizificating
        
        if next.rows == higherRow && next.cols == higherCol {
            direction = -1
        }
        if next.rows == lowerRow && next.cols == lowerCol {
            direction = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            self.resizificating = direction
            self.queueNextSize()
        }
    }
    
    var resizificating = 0
    
    @objc @IBAction
    func resizificator (_ source: AnyObject)
    {
        if resizificating != 1 {
            resizificating = 1
            queueNextSize ()
        } else {
            resizificating = 0
        }
    }

    @objc @IBAction
    func resizificatorDown (_ source: AnyObject)
    {
        if resizificating != -1 {
            resizificating = -1
            queueNextSize ()
        } else {
            resizificating = 0
        }
    }

    /// Cycles Core Graphics -> Metal on MTKView -> Metal on the layer surface.
    ///
    /// Three positions on one menu item rather than two items, because there
    /// are now three renderers worth comparing and switching between them in
    /// place is the point: a frame that looks wrong can be checked against the
    /// other two without relaunching and losing what provoked it.
    @objc @IBAction
    func toggleMetalRenderer(_ source: AnyObject) {
        do {
            if !terminal.isUsingMetalRenderer {
                try terminal.setUsesMetalLayerSurface(false)
                try terminal.setUseMetal(true)
            } else if !terminal.usesMetalLayerSurface {
                try terminal.setUsesMetalLayerSurface(true)
            } else {
                try terminal.setUseMetal(false)
            }
        } catch {
            print("METAL TOGGLE FAILED: \(error)")
        }
        terminal.setNeedsDisplay(terminal.bounds)
    }

    @objc @IBAction
    func toggleMetalBufferingMode(_ source: AnyObject) {
        let current = terminal.metalBufferingMode
        terminal.metalBufferingMode = (current == .perRowPersistent) ? .perFrameAggregated : .perRowPersistent
        terminal.setNeedsDisplay(terminal.bounds)
    }

    @objc @IBAction
    func allowMouseReporting (_ source: AnyObject)
    {
        terminal.allowMouseReporting.toggle ()
    }

    @objc @IBAction
    func toggleCustomBlockGlyphs (_ source: AnyObject)
    {
        terminal.customBlockGlyphs.toggle()
    }

    @objc @IBAction
    func toggleAnsi256PaletteStrategy (_ source: AnyObject)
    {
        let term = terminal.getTerminal()
        term.ansi256PaletteStrategy = nextAnsi256PaletteStrategy(after: term.ansi256PaletteStrategy)
    }
    
    @objc @IBAction
    func exportBuffer (_ source: AnyObject)
    {
        saveData { self.terminal.getTerminal().getBufferAsData () }
    }

    @objc @IBAction
    func exportSelection (_ source: AnyObject)
    {
        saveData {
            if let str = self.terminal.getSelection () {
                return str.data (using: .utf8) ?? Data ()
            }
            return Data ()
        }
    }

    func saveData (_ getData: @escaping () -> Data)
    {
        let savePanel = NSSavePanel ()
        savePanel.canCreateDirectories = true
        if #available(macOS 12.0, *) {
            savePanel.allowedContentTypes = [UTType.text, UTType.plainText]
        } else {
            savePanel.allowedFileTypes = ["txt"]
        }
        savePanel.title = "Export Buffer Contents As Text"
        savePanel.nameFieldStringValue = "TerminalCapture"
        
        savePanel.begin { (result) in
            if result.rawValue == NSApplication.ModalResponse.OK.rawValue {
                let data = getData ()
                if let url = savePanel.url {
                    do {
                        try data.write(to: url)
                    } catch let error as NSError {
                        let alert = NSAlert (error: error)
                        alert.runModal()
                    }
                }
            }
        }
    }
    
    @objc @IBAction
    func softReset (_ source: AnyObject)
    {
        terminal.getTerminal().softReset ()
        terminal.setNeedsDisplay(terminal.frame)
    }
    
    @objc @IBAction
    func hardReset (_ source: AnyObject)
    {
        terminal.getTerminal().resetToInitialState ()
        terminal.setNeedsDisplay(terminal.frame)
    }
    
    @objc @IBAction
    func toggleOptionAsMetaKey (_ source: AnyObject)
    {
        terminal.optionAsMetaKey.toggle ()
    }
    
    @objc @IBAction
    func biggerFont (_ source: AnyObject)
    {
        let size = terminal.font.pointSize
        guard size < 72 else {
            return
        }
        
        terminal.font = NSFont.monospacedSystemFont(ofSize: size+1, weight: .regular)
    }

    @objc @IBAction
    func smallerFont (_ source: AnyObject)
    {
        let size = terminal.font.pointSize
        guard size > 5 else {
            return
        }
        
        terminal.font = NSFont.monospacedSystemFont(ofSize: size-1, weight: .regular)
    }

    @objc @IBAction
    func defaultFontSize  (_ source: AnyObject)
    {
        terminal.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }
    

    @objc @IBAction
    func addTab (_ source: AnyObject)
    {
        
//        if let win = view.window {
//            win.tabbingMode = .preferred
//            if let wc = win.windowController {
//                if let d = wc.document as? Document {
//                    do {
//                        let x = Document()
//                        x.makeWindowControllers()
//                        
//                        try NSDocumentController.shared.newDocument(self)
//                    } catch {}
//                    print ("\(d.debugDescription)")
//                }
//            }
//        }
//            win.tabbingMode = .preferred
//            win.addTabbedWindow(win, ordered: .above)
//
//            if let wc = win.windowController {
//                wc.newWindowForTab(self()
//                wc.showWindow(source)
//            }
//        }
    }
    
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool
    {
        if item.action == #selector(debugToggleHostLogging(_:)) {
            if let m = item as? NSMenuItem {
                m.state = logging ? NSControl.StateValue.on : NSControl.StateValue.off
            }
        }
        if item.action == #selector(resizificator(_:)) {
            if let m = item as? NSMenuItem {
                m.state = resizificating == 1 ? NSControl.StateValue.on : NSControl.StateValue.off
            }
        }
        if item.action == #selector(resizificatorDown(_:)) {
            if let m = item as? NSMenuItem {
                m.state = resizificating == -1 ? NSControl.StateValue.on : NSControl.StateValue.off
            }
        }
        if item.action == #selector(allowMouseReporting(_:)) {
            if let m = item as? NSMenuItem {
                m.state = terminal.allowMouseReporting ? NSControl.StateValue.on : NSControl.StateValue.off
            }
        }
        if item.action == #selector(toggleCustomBlockGlyphs(_:)) {
            if let m = item as? NSMenuItem {
                m.state = terminal.customBlockGlyphs ? NSControl.StateValue.on : NSControl.StateValue.off
            }
        }
        if item.action == #selector(toggleAnsi256PaletteStrategy(_:)) {
            if let m = item as? NSMenuItem {
                let term = terminal.getTerminal()
                let strategy = term.ansi256PaletteStrategy
                m.title = ansi256PaletteMenuTitle(for: strategy)
                m.state = ansi256PaletteMenuState(for: strategy)
            }
        }
        if item.action == #selector(toggleOptionAsMetaKey(_:)) {
            if let m = item as? NSMenuItem {
                m.state = terminal.optionAsMetaKey ? NSControl.StateValue.on : NSControl.StateValue.off
            }
        }
        if item.action == #selector(toggleMetalRenderer(_:)) {
            if let m = item as? NSMenuItem {
                m.state = terminal.isUsingMetalRenderer ? .on : .off
                // A checkmark cannot say which of three is running, and the
                // whole point of the item is knowing that at a glance.
                m.title = "Renderer: \(rendererDescription)"
            }
        }
        if item.action == #selector(toggleMetalBufferingMode(_:)) {
            if let m = item as? NSMenuItem {
                m.state = terminal.metalBufferingMode == .perFrameAggregated ? .on : .off
            }
        }
        if item.action == #selector(toggleReverseVideoTest(_:)) {
            if let m = item as? NSMenuItem {
                m.state = reverseVideoTestState == nil ? .off : .on
            }
        }
        
        // Only enable "Export selection" if we have a selection
        if item.action == #selector(exportSelection(_:)) {
            return terminal.selectionActive
        }
        return true
    }

    private func nextAnsi256PaletteStrategy(after strategy: Ansi256PaletteStrategy) -> Ansi256PaletteStrategy {
        switch strategy {
        case .xterm:
            return .base16Lab
        case .base16Lab:
            return .base16LabHarmonious
        case .base16LabHarmonious:
            return .xterm
        }
    }

    private func ansi256PaletteMenuTitle(for strategy: Ansi256PaletteStrategy) -> String {
        switch strategy {
        case .xterm:
            return "ANSI 256 Palette: xterm"
        case .base16Lab:
            return "ANSI 256 Palette: Base16 LAB"
        case .base16LabHarmonious:
            return "ANSI 256 Palette: Base16 LAB Harmonious"
        }
    }

    private func ansi256PaletteMenuState(for strategy: Ansi256PaletteStrategy) -> NSControl.StateValue {
        switch strategy {
        case .xterm:
            return .off
        case .base16Lab:
            return .on
        case .base16LabHarmonious:
            return .mixed
        }
    }
    
    @objc @IBAction
    func debugToggleHostLogging (_ source: AnyObject)
    {
        logging = !logging
        updateLogging()
    }

    // MARK: - IO baselines (io-gaps.md C0.2)

    @objc @IBAction
    func debugRunBaselineFlood (_ source: AnyObject)
    {
        runBaseline(.flood)
    }

    @objc @IBAction
    func debugRunBaselineBidiFlood (_ source: AnyObject)
    {
        runBaseline(.bidiFlood)
    }

    @objc @IBAction
    func debugRunBaselineTui (_ source: AnyObject)
    {
        runBaseline(.tui)
    }

    @objc @IBAction
    func debugRunBaselineBinary (_ source: AnyObject)
    {
        runBaseline(.binary)
    }

    /// Sends `command` once terminal output has been still for three polls,
    /// which means the shell has started and printed its prompt.
    private func sendWhenShellIsReady (_ command: String) {
        var lastBytes = -1
        var quietPolls = 0
        func poll() {
            let bytes = terminal.diagnostics.bytesFed
            if bytes == lastBytes {
                quietPolls += 1
            } else {
                quietPolls = 0
                lastBytes = bytes
            }
            if quietPolls >= 3 && bytes > 0 {
                let line = command + "\n"
                terminal.send(source: terminal, data: Array(line.utf8)[...])
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: poll)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: poll)
    }

    /// Measures frames drawn while the terminal cannot be seen, three ways.
    ///
    /// The first version of this used `orderOut`, and it proved nothing:
    /// AppKit stops a `CADisplayLink` attached to a view in an ordered-out
    /// window by itself, so the run passed identically with G8b disabled. The
    /// gap is about a window that is still on screen and still `isVisible` —
    /// merely covered — which AppKit does not handle. Covering it with an
    /// opaque window is what produces the real case.
    private func runOcclusionScenario () {
        guard let window = view.window else {
            print("===BASELINE-BEGIN===\nUNAVAILABLE: no window\n===BASELINE-END===")
            exit(2)
        }
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window.makeKeyAndOrderFront(nil)
        terminal.send(source: terminal,
                      data: Array("while true; do seq 1 500; done\n".utf8)[...])

        var cover: NSWindow?
        var rows: [(String, Int, Bool)] = []

        func measure (_ label: String, seconds: Double, expectDraws: Bool,
                      enter: @escaping () -> Void, leave: @escaping () -> Void,
                      then: @escaping () -> Void) {
            enter()
            // Settle first: the frame in flight when the state changed still
            // completes, and counting it would be wrong.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let before = self.terminal.diagnostics.renders
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    rows.append((label, self.terminal.diagnostics.renders - before,
                                 expectDraws))
                    leave()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: then)
                }
            }
        }

        func makeCover () {
            let covering = NSWindow(contentRect: window.frame,
                                    styleMask: [.borderless],
                                    backing: .buffered, defer: false)
            covering.isOpaque = true
            covering.backgroundColor = .black
            covering.level = .floating
            covering.setFrame(window.frame, display: true)
            covering.orderFrontRegardless()
            cover = covering
        }

        measure("covered by an opaque window", seconds: 3.0, expectDraws: false,
                enter: makeCover,
                leave: { cover?.orderOut(nil); cover = nil }) {
            measure("miniaturised", seconds: 3.0, expectDraws: false,
                    enter: { window.miniaturize(nil) },
                    leave: { window.deminiaturize(nil) }) {
                measure("visible", seconds: 2.0, expectDraws: true,
                        enter: {}, leave: {}) {
                    self.terminal.send(source: self.terminal,
                                       data: Array("\u{3}".utf8)[...])
                    let failures = rows.filter { _, count, expect in
                        expect ? count == 0 : count != 0
                    }
                    print("===BASELINE-BEGIN===")
                    print("## Occlusion [\(self.rendererDescription)]\n")
                    print("| State | Renders | Expected |\n| --- | --- | --- |")
                    for (label, count, expect) in rows {
                        print("| \(label) | \(count) | \(expect ? "> 0" : "0") |")
                    }
                    print("| Result | \(failures.isEmpty ? "pass" : "FAIL") | |")
                    print("===BASELINE-END===")
                    fflush(stdout)
                    exit(failures.isEmpty ? 0 : 4)
                }
            }
        }
    }

    /// Flips Metal on and off repeatedly while output streams.
    private func runMetalToggleScenario () {
        var flips = 0
        var failures: [String] = []

        func flip () {
            guard let harness = baselineHarness, harness.isRunning else { return }
            if terminal.diagnostics.bytesFed > 1_000_000 {
                do {
                    try terminal.setUseMetal(!terminal.isUsingMetalRenderer)
                    flips += 1
                } catch {
                    failures.append("flip \(flips + 1): \(error)")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: flip)
        }

        // After the load: settle in each state and prove it still draws. A
        // renderer that silently stops after a toggle is the failure mode.
        var settled: [String] = []
        func settleAndDraw (remaining: Int, _ done: @escaping () -> Void) {
            guard remaining > 0 else { return done() }
            do {
                try terminal.setUseMetal(remaining % 2 == 0)
            } catch {
                failures.append("settle \(remaining): \(error)")
            }
            let name = self.rendererDescription
            self.terminal.resetDiagnostics()
            self.terminal.feed(text: "settle \(remaining)\r\n")
            self.terminal.requestRedraw()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let drew = self.terminal.diagnostics.renders > 0
                settled.append("\(name): \(drew ? "draws" : "DEAD")")
                if !drew { failures.append("\(name) drew nothing after a toggle") }
                settleAndDraw(remaining: remaining - 1, done)
            }
        }

        if baselineHarness == nil {
            baselineHarness = IOBaselineHarness(terminal: terminal)
        }
        guard let harness = baselineHarness, !harness.isRunning else { exit(2) }
        harness.terminateOnTimeout = true
        harness.run(.bidiFlood) { [weak self] report in
            guard let self else { exit(2) }
            settleAndDraw(remaining: 4) {
                print("===BASELINE-BEGIN===")
                print(report)
                print("\n### Metal toggled on and off under load\n")
                print("| Measurement | Value |\n| --- | --- |")
                print("| Flips under load | \(flips) |")
                for entry in settled {
                    print("| After a toggle | \(entry) |")
                }
                print("| Failures | \(failures.isEmpty ? "none" : failures.joined(separator: "; ")) |")
                print("| Survived | \(failures.isEmpty ? "yes" : "NO") |")
                print("===BASELINE-END===")
                fflush(stdout)
                exit(failures.isEmpty ? 0 : 4)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: flip)
    }

    /// Cycles Core Graphics -> MTKView -> layer+loop repeatedly under load.
    private func runSurfaceSwitchScenario () {
        var switches = 0
        var seen: Set<String> = []
        var failures: [String] = []

        func cycle () {
            guard let harness = baselineHarness, harness.isRunning else { return }
            if terminal.diagnostics.bytesFed > 1_000_000 {
                self.toggleMetalRenderer(self)
                switches += 1
                seen.insert(self.rendererDescription)
                // No per-switch draw check here: rebuilding the surface
                // builds a new MetalTerminalRenderer, whose render counter
                // starts at zero, so `renders` jumps backwards across a switch
                // and any delta computed over one is meaningless. The
                // settle-and-draw check after the flood is the real assertion.
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30, execute: cycle)
        }

        if baselineHarness == nil {
            baselineHarness = IOBaselineHarness(terminal: terminal)
        }
        guard let harness = baselineHarness, !harness.isRunning else { exit(2) }
        harness.terminateOnTimeout = true
        // After the flood: settle on each renderer in turn and prove it still
        // draws. This is the assertion the per-switch counter could not make.
        var settleResults: [String] = []
        func settleAndDraw (remaining: Int, _ done: @escaping () -> Void) {
            guard remaining > 0 else { return done() }
            self.toggleMetalRenderer(self)
            let name = self.rendererDescription
            self.terminal.resetDiagnostics()
            self.terminal.feed(text: "settle \(remaining)\r\n")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let drew = self.terminal.diagnostics.renders > 0
                settleResults.append("\(name): \(drew ? "draws" : "DEAD")")
                if !drew { failures.append("\(name) drew nothing after switching") }
                settleAndDraw(remaining: remaining - 1, done)
            }
        }

        harness.run(.bidiFlood) { [weak self] report in
            guard let self else { exit(2) }
            settleAndDraw(remaining: 3) {
                print("===BASELINE-BEGIN===")
                print(report)
                print("\n### Renderer switching under load\n")
                print("| Measurement | Value |\n| --- | --- |")
                print("| Switches under load | \(switches) |")
                print("| Renderers seen | \(seen.sorted().joined(separator: ", ")) |")
                for result in settleResults {
                    print("| After switching | \(result) |")
                }
                print("| Failures | \(failures.isEmpty ? "none" : failures.joined(separator: "; ")) |")
                print("| Survived | \(failures.isEmpty ? "yes" : "NO") |")
                print("===BASELINE-END===")
                fflush(stdout)
                exit(failures.isEmpty ? 0 : 4)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: cycle)
    }

    /// Measures input-to-glyph latency: send one byte, wait for the frame that
    /// carries its echo.
    ///
    /// The terminal is idled between samples on purpose. That is both the case
    /// users feel — a prompt sitting still, then a keystroke — and the case
    /// G4 is about, because an idle terminal has let the display link pause, so
    /// the sample includes the resume path.
    ///
    /// Each sample sends one printable character, which the shell echoes; the
    /// next completed frame is therefore the one carrying it. Nothing else is
    /// drawing, because MacTerminal's cursor is `steadyBlock`.
    private func runInputLatencyScenario () {
        let samples = 40
        let idleBetweenSamples = 0.30
        var latenciesMs: [Double] = []

        let pending = NSLock()
        var awaiting: DispatchTime?
        var recorded: Double?

        TerminalView.onFramePresented = {
            let now = DispatchTime.now()
            pending.lock()
            if let sent = awaiting, recorded == nil {
                recorded = Double(now.uptimeNanoseconds &- sent.uptimeNanoseconds) / 1_000_000
            }
            pending.unlock()
        }

        func sample (_ index: Int) {
            guard index < samples else { return finish() }
            pending.lock()
            awaiting = DispatchTime.now()
            recorded = nil
            pending.unlock()
            terminal.send(source: terminal, data: Array("a".utf8)[...])

            // Poll for the frame rather than calling back from the render
            // thread: the callback must stay short, and a 1 ms poll cannot
            // perturb a measurement whose floor is a frame period.
            func waitForFrame (attemptsLeft: Int) {
                pending.lock()
                let value = recorded
                pending.unlock()
                if let value {
                    latenciesMs.append(value)
                } else if attemptsLeft > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) {
                        waitForFrame(attemptsLeft: attemptsLeft - 1)
                    }
                    return
                }
                pending.lock()
                awaiting = nil
                pending.unlock()
                DispatchQueue.main.asyncAfter(deadline: .now() + idleBetweenSamples) {
                    sample(index + 1)
                }
            }
            waitForFrame(attemptsLeft: 500)
        }

        func finish () {
            TerminalView.onFramePresented = nil
            // Clear the line of 'a's rather than leaving it for the shell.
            terminal.send(source: terminal, data: Array("\u{15}".utf8)[...])
            let sorted = latenciesMs.sorted()
            func percentile (_ p: Double) -> Double {
                guard !sorted.isEmpty else { return 0 }
                let index = min(sorted.count - 1,
                                max(0, Int((Double(sorted.count) * p).rounded(.down))))
                return sorted[index]
            }
            let mean = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
            print("===BASELINE-BEGIN===")
            print("## Input to glyph [\(self.rendererDescription)]\n")
            print("| Measurement | Value |\n| --- | --- |")
            print("| Samples | \(sorted.count) of \(samples) |")
            print(String(format: "| Mean | %.2f ms |", mean))
            print(String(format: "| p50 | %.2f ms |", percentile(0.50)))
            print(String(format: "| p99 | %.2f ms |", percentile(0.99)))
            print(String(format: "| Max | %.2f ms |", sorted.last ?? 0))
            print("===BASELINE-END===")
            fflush(stdout)
            exit(sorted.count == samples ? 0 : 4)
        }

        // Let the shell settle first, or the first samples race its prompt.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { sample(0) }
    }

    private var rendererDescription: String {
        guard terminal.isUsingMetalRenderer else { return "CoreGraphics" }
        return terminal.isUsingRenderLoop ? "Metal, layer + render loop" : "Metal, MTKView"
    }

    /// Resizes the window and changes the font repeatedly while a flood runs.
    ///
    /// Every one of these mutates state the render loop reads for the next
    /// frame — window size, drawable size, cell dimension, fonts — from the
    /// main thread. The report is the usual load-case table plus proof that
    /// the terminal survived and the final frame matches the final geometry.
    private func runResizeFloodScenario () {
        guard let window = view.window else {
            print("===BASELINE-BEGIN===\nUNAVAILABLE: no window\n===BASELINE-END===")
            exit(2)
        }
        let originalFrame = window.frame
        let originalFont = terminal.font

        let sizes: [NSSize] = [NSSize(width: 1100, height: 780),
                               NSSize(width: 640, height: 460),
                               NSSize(width: 980, height: 700),
                               NSSize(width: 720, height: 560)]
        // Churn only while the flood is actually streaming.
        //
        // Resizing sends SIGWINCH and the shell reprints its prompt, so a
        // resize outside the flood keeps the byte counter moving — and the
        // harness detects both the start and the end of a load by that counter
        // going quiet. Churning through those windows wedges the run forever,
        // which is exactly what the first version of this did.
        var step = 0
        var lastBytes = 0
        var churn: (() -> Void)!
        churn = { [weak self] in
            guard let self, self.baselineHarness?.isRunning == true else { return }
            let bytes = self.terminal.diagnostics.bytesFed
            let streaming = bytes - lastBytes > 1_000_000
            lastBytes = bytes
            if streaming && step < 12 {
                var frame = originalFrame
                frame.size = sizes[step % sizes.count]
                window.setFrame(frame, display: false)
                // Alternate the font so cell dimensions move too, not just
                // bounds.
                if step % 2 == 0 {
                    self.biggerFont(self)
                } else {
                    self.smallerFont(self)
                }
                step += 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: churn)
        }

        if baselineHarness == nil {
            baselineHarness = IOBaselineHarness(terminal: terminal)
        }
        guard let harness = baselineHarness, !harness.isRunning else { exit(2) }
        harness.terminateOnTimeout = true
        harness.run(.bidiFlood) { [weak self] report in
            guard let self else { exit(2) }
            let diagnostics = self.terminal.diagnostics
            let cols = self.terminal.getTerminal().cols
            let rows = self.terminal.getTerminal().rows
            // Restore, so a later launch does not inherit a stretched window
            // or a font size nobody asked for.
            window.setFrame(originalFrame, display: true)
            self.terminal.font = originalFont

            print("===BASELINE-BEGIN===")
            print(report)
            print("\n### Resize and font churn\n")
            print("| Measurement | Value |\n| --- | --- |")
            print("| Geometry changes | \(step) |")
            print("| Final terminal size | \(cols)x\(rows) |")
            print("| Renders (actually drawn) | \(diagnostics.renders) |")
            print("| Render-loop frames | \(diagnostics.renderLoopFrames) |")
            print("| Survived | \(diagnostics.renders > 0 && cols > 0 && rows > 0 ? "yes" : "NO") |")
            print("===BASELINE-END===")
            fflush(stdout)
            exit(diagnostics.renders > 0 ? 0 : 4)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: churn)
    }

    /// Reports frames drawn over an idle window, which is the cursor blink.
    ///
    /// A blinking cursor toggles every 0.7 s and asks for a redraw each time,
    /// so a healthy run draws roughly `seconds / 0.7` frames. Near zero means
    /// the blink timer is not firing.
    ///
    /// Metal paths only. Core Graphics blinks `caretView` with a Core Animation
    /// animation and draws no frames for it, so it reports zero and that is
    /// correct.
    private func runIdleCursorScenario () {
        guard let window = view.window else {
            print("===BASELINE-BEGIN===\nUNAVAILABLE: no window\n===BASELINE-END===")
            exit(2)
        }
        // The renderer only blinks a focused cursor, so the window has to be
        // key or this measures nothing. Activation is asynchronous and racing
        // whichever terminal launched us, so poll for it rather than assuming
        // one delay is enough.
        let seconds = 6.0
        func waitForKey (attemptsLeft: Int, _ done: @escaping () -> Void) {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            window.makeKeyAndOrderFront(nil)
            self.terminal.window?.makeFirstResponder(self.terminal)
            if window.isKeyWindow || attemptsLeft == 0 {
                done()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                waitForKey(attemptsLeft: attemptsLeft - 1, done)
            }
        }

        waitForKey(attemptsLeft: 20) { [weak self] in
            guard let self else { exit(2) }
            // MacTerminal's cursor is steadyBlock, so ask for a blinking one
            // (DECSCUSR 1) — otherwise this measures a cursor that is correct
            // to never redraw, and reports it as a failure.
            self.terminal.feed(text: "\u{1b}[1 q")
            // Focus drives the blink, and a window launched from a shell does
            // not reliably hold the keyboard for six seconds. Taking focus out
            // of the equation is what makes this measure the timer rather than
            // the window server.
            self.terminal.caretViewTracksFocus = false
            self.terminal.resetDiagnostics()
            let hadFocus = window.isKeyWindow
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                let diagnostics = self.terminal.diagnostics
                // One redraw per toggle, and the toggle period is 0.7 s. Slack
                // of two for the partial periods at each end.
                let expected = Int((seconds / 0.7).rounded(.down)) - 2
                print("===BASELINE-BEGIN===")
                print("## Idle cursor blink\n")
                print("| Measurement | Value |\n| --- | --- |")
                print("| Window was key | \(hadFocus ? "yes" : "NO") |")
                print("| View has focus | \(self.terminal.hasFocus ? "yes" : "NO") |")
                print("| Cursor style | \(self.terminal.getTerminal().options.cursorStyle) |")
                print(String(format: "| Idle seconds | %.1f |", seconds))
                print("| Renders (actually drawn) | \(diagnostics.renders) |")
                print("| Frame ticks | \(diagnostics.frames) |")
                print("| Render-loop frames | \(diagnostics.renderLoopFrames) |")
                print("| Expected at least | \(expected) |")
                print("| Blinking | \(diagnostics.renders >= expected ? "yes" : "NO") |")
                print("===BASELINE-END===")
                fflush(stdout)
                exit(diagnostics.renders >= expected ? 0 : 4)
            }
        }
    }

    /// Moves the window to a second display and back while output streams,
    /// reporting the backing scale seen on each and whether frames kept coming.
    private func runDisplayMoveScenario () {
        guard let window = view.window else {
            print("===BASELINE-BEGIN===\nUNAVAILABLE: no window\n===BASELINE-END===")
            exit(2)
        }
        let secondary = NSScreen.screens.first { screen in
            screen.localizedName.contains("DELL")
                || screen.backingScaleFactor != (window.screen?.backingScaleFactor ?? 2)
        }
        guard let secondary, let primary = window.screen else {
            print("===BASELINE-BEGIN===\nUNAVAILABLE: no second display with a different scale\n"
                  + "screens: \(NSScreen.screens.map { "\($0.localizedName)@\($0.backingScaleFactor)x" })\n"
                  + "===BASELINE-END===")
            exit(2)
        }

        // Restored at the end: leaving the window centred on another display
        // means macOS restores that position on the next launch, and if that
        // display is asleep the window comes back off-screen — invisible, with
        // the app apparently running fine.
        let originalFrame = window.frame

        let monitor = MainThreadStallMonitor()
        terminal.resetDiagnostics()
        TerminalProfiling.reset()
        monitor.start()
        let started = DispatchTime.now()

        // Stream output for the whole scenario so frames are actually needed.
        terminal.send(txt: "yes 'display move scenario 0123456789' | head -c 41943040\n")

        func center(_ window: NSWindow, on screen: NSScreen) {
            let visible = screen.visibleFrame
            var frame = window.frame
            frame.origin.x = visible.midX - frame.width / 2
            frame.origin.y = visible.midY - frame.height / 2
            window.setFrame(frame, display: true)
            window.makeKeyAndOrderFront(nil)
        }

        var framesOnPrimary = 0
        var scaleOnSecondary: CGFloat = 0

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            framesOnPrimary = self.terminal.diagnostics.frames
            center(window, on: secondary)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            scaleOnSecondary = window.screen?.backingScaleFactor ?? 0
            center(window, on: primary)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            window.setFrame(originalFrame, display: true)
            monitor.stop()
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds
                                 &- started.uptimeNanoseconds) / 1_000_000_000.0
            let diagnostics = self.terminal.diagnostics
            let stalls = monitor.summarize()
            let framesOnSecondary = diagnostics.frames - framesOnPrimary

            print("===BASELINE-BEGIN===")
            print("## Display move (\(primary.localizedName) -> \(secondary.localizedName))\n")
            print("| Measurement | Value |\n| --- | --- |")
            print(String(format: "| Elapsed | %.2f s |", elapsed))
            print(String(format: "| Primary scale | %.1fx |", primary.backingScaleFactor))
            print(String(format: "| Secondary scale | %.1fx |", secondary.backingScaleFactor))
            print(String(format: "| Scale seen while on secondary | %.1fx |", scaleOnSecondary))
            print("| Frames before move | \(framesOnPrimary) |")
            print("| Frames after move | \(framesOnSecondary) |")
            print("| Bytes fed | \(diagnostics.bytesFed) |")
            print(String(format: "| Stall p99 | %.2f ms |", stalls.p99Ms))
            print(String(format: "| Stall max | %.2f ms |", stalls.maxMs))
            // The property that matters: rendering must continue on the
            // second display, and the scale must follow the window.
            let ok = framesOnSecondary > 0
                && abs(scaleOnSecondary - secondary.backingScaleFactor) < 0.01
            print("| Kept rendering after move | \(ok ? "yes" : "NO") |")
            print("===BASELINE-END===")
            fflush(stdout)
            exit(ok ? 0 : 5)
        }
    }

    private func runBaseline (_ loadCase: IOBaselineHarness.Case, exitWhenDone: Bool = false)
    {
        if baselineHarness == nil {
            baselineHarness = IOBaselineHarness(terminal: terminal)
        }
        guard let harness = baselineHarness, !harness.isRunning else {
            return
        }
        harness.terminateOnTimeout = exitWhenDone
        harness.run(loadCase) { report in
            // Both destinations on purpose: the pasteboard so the number can go
            // straight into Docs/io-baselines.md, and stdout so a run driven
            // from a script still records it.
            print("===BASELINE-BEGIN===")
            print(report)
            print("===BASELINE-END===")
            fflush(stdout)

            if exitWhenDone {
                exit(0)
            }

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)

            let alert = NSAlert()
            alert.messageText = "IO baseline complete"
            alert.informativeText = report + "\nCopied to the clipboard."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func runBaselineSuite(
        _ cases: [IOBaselineHarness.Case],
        repeatCount: Int,
        label: String
    ) {
        if baselineHarness == nil {
            baselineHarness = IOBaselineHarness(terminal: terminal)
        }
        guard let harness = baselineHarness, !harness.isRunning else { return }
        harness.terminateOnTimeout = true
        harness.runSuite(
            cases: cases,
            repeatCount: repeatCount,
            label: label,
            result: { report, machineLine in
                print("===BASELINE-BEGIN===")
                if !machineLine.isEmpty {
                    print(machineLine)
                }
                print(report)
                print("===BASELINE-END===")
                fflush(stdout)
            },
            completion: {
                exit(0)
            })
    }

    /// Runs one load case and exits. Scripted runs are the point: a baseline
    /// that needs a human to click a menu will not be re-measured after every
    /// change.
    ///
    /// Selected by `SWIFTTERM_BASELINE=<case>|all|quick`, or by the single-token
    /// `--baseline=<case>` form. There is deliberately no `--baseline <case>`
    /// spelling: this is a document-based app, so a bare trailing token is
    /// taken as a file to open and raises "The document could not be opened".
    /// True once one window has claimed the run.
    ///
    /// MacTerminal is document based and restores a document *and* opens a new
    /// one, so `viewDidLoad` runs twice on launch. Without this guard both
    /// windows ran the load case: two floods on one machine, each halving the
    /// other's throughput, and the report came from whichever finished first.
    /// Every number measured that way was depressed by an invisible second
    /// terminal. Screenshotting both windows mid-run is how it was found.
    private static var baselineClaimed = false
    private static var commandClaimed = false

    private func startBaselineFromLaunchArguments ()
    {
        let environment = ProcessInfo.processInfo.environment["SWIFTTERM_BASELINE"]
        let argument = ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix("--baseline=") }
            .map { String($0.dropFirst("--baseline=".count)) }
        guard let name = environment ?? argument, !name.isEmpty else {
            return
        }
        guard !ViewController.baselineClaimed else { return }
        ViewController.baselineClaimed = true
        if name == "displaymove" {
            // Drives the window across displays with different backing scales
            // while output streams. This is the `rebindMetalView` path, where
            // layer-backed surfaces classically break. Run it against the
            // MTKView path first to establish a baseline, then against the
            // layer path to detect a regression.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.runDisplayMoveScenario()
            }
            return
        }

        if name == "occlusion" {
            // G8b's acceptance: an occluded window with a flood running draws
            // nothing, and the first frame after unocclusion shows the state
            // that accumulated. Ordering the window out is the closest thing
            // to occlusion a script can produce; it drives the same
            // notification path.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.runOcclusionScenario()
            }
            return
        }

        if name == "metaltoggle" {
            // The shape a host exposes as a "use the GPU renderer" preference:
            // Metal flipped on and off repeatedly, under load. Distinct from
            // `surfaceswitch`, which cycles all three renderers — this is the
            // two-state toggle an embedder actually ships.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.runMetalToggleScenario()
            }
            return
        }

        if name == "surfaceswitch" {
            // Cycles the renderer repeatedly while output streams. Switching
            // surfaces tears down a live CAMetalLayer and a running render
            // loop and builds their replacements, which is the one thing the
            // runtime switch does that the launch flag never had to.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.runSurfaceSwitchScenario()
            }
            return
        }

        if name == "inputlatency" {
            // C0.2 case 3, the last load case that had no number. Measures the
            // gap between sending a byte and the frame carrying its echo
            // completing on the GPU.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.runInputLatencyScenario()
            }
            return
        }

        if name == "resizeflood" {
            // Resizes the window and changes the font while a flood runs.
            // Both mutate the geometry the render loop is reading from —
            // drawable size, contents scale, cell dimension — so this is where
            // WO-F4 would tear if the handover were wrong. Worth running under
            // the thread sanitizer, which is the only tool that sees the
            // failure before it becomes a crash.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.runResizeFloodScenario()
            }
            return
        }

        if name == "idlecursor" {
            // Counts frames drawn while nothing is happening, which is the
            // cursor blink and nothing else. It exists because a screenshot
            // cannot see it: `screencapture -l` of a Metal-backed window
            // returns the same bytes every time, on both surfaces, so the
            // obvious check silently passes whatever the renderer does.
            //
            // The blink is a Timer, and WO-F4 moved the code that starts it
            // onto a thread with no run loop. A timer scheduled there never
            // fires and the cursor just stops blinking.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.runIdleCursorScenario()
            }
            return
        }

        if name == "surfaceparity" {
            // Not a load case: renders the same content through both Metal
            // surfaces and reports the pixel difference. This is the WO-F3
            // regression net, and it can only run where the shader bundle
            // exists — that is, inside the app.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { exit(2) }
                _ = self
                let result = TerminalView.compareMetalSurfaces()
                print("===BASELINE-BEGIN===")
                print("## Metal surface parity\n")
                if let reason = result.unavailableReason {
                    print("UNAVAILABLE: \(reason)")
                } else {
                    print("| Measurement | Value |\n| --- | --- |")
                    print("| Pixels compared | \(result.totalPixels) |")
                    print("| Differing pixels | \(result.differingPixels) |")
                    print("| Non-uniform pixels (proof it drew) | \(result.nonUniformPixels) |")
                    print("| Match | \(result.matches ? "yes" : "NO") |")
                }
                print("===BASELINE-END===")
                fflush(stdout)
                exit(result.matches ? 0 : 4)
            }
            return
        }

        let cases: [IOBaselineHarness.Case]
        if name == "all" {
            cases = IOBaselineHarness.Case.vteBenchCases
        } else if name == "quick" {
            cases = IOBaselineHarness.Case.quickCases
        } else if let loadCase = IOBaselineHarness.Case(rawValue: name) {
            cases = [loadCase]
        } else {
            print("unknown baseline case: \(name)")
            exit(2)
        }
        let repeatText = ProcessInfo.processInfo.environment["SWIFTTERM_BASELINE_REPEAT"] ?? "1"
        guard let repeatCount = Int(repeatText), repeatCount > 0 else {
            print("SWIFTTERM_BASELINE_REPEAT must be a positive integer")
            exit(2)
        }
        let label = ProcessInfo.processInfo.environment["SWIFTTERM_BASELINE_LABEL"]
            ?? "unlabelled"
        // The delay lets the shell start and print its prompt, so the command
        // is not typed into a shell that is not listening yet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.runBaselineSuite(cases, repeatCount: repeatCount, label: label)
        }
    }
}
