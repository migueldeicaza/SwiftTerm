import AppKit
import Foundation
import QuartzCore
import SwiftTerm
import WebKit

final class HarnessViewController: NSViewController, TerminalViewDelegate, WKNavigationDelegate {
    let terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 408), font: NSFont(name: "Menlo", size: 14))

    private let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    private let splitView = NSSplitView()
    private let inspector = NSTextView()
    private let scenarioPopup = NSPopUpButton()
    private let stepLabel = NSTextField(labelWithString: "No step")
    private let colsField = NSTextField(string: "80")
    private let rowsField = NSTextField(string: "24")
    private let rendererPopup = NSPopUpButton()
    private let policyPopup = NSPopUpButton()

    private let store: ScenarioStore
    private let artifactRoot: URL
    private let runID: String
    private(set) var currentScenario: HarnessScenario?
    private(set) var currentStepIndex = -1
    private(set) var outgoingBytes = Data()
    private var lastAssertionResults: [AssertionResult] = []
    private var actionTimingsMilliseconds: [String: Double] = [:]
    private var didInstallInitialScenario = false
    private var referenceLoadPending = false

    init(store: ScenarioStore, artifactRoot: URL, runID: String) {
        self.store = store
        self.artifactRoot = artifactRoot
        self.runID = runID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1440, height: 650))
        view.wantsLayer = true

        terminalView.terminalDelegate = self
        terminalView.nativeForegroundColor = NSColor(calibratedWhite: 0.93, alpha: 1)
        terminalView.nativeBackgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1)
        terminalView.caretViewTracksFocus = false
        terminalView.allowMouseReporting = false

        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(terminalView)
        splitView.addArrangedSubview(webView)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        terminalView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        webView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        inspector.isEditable = false
        inspector.isSelectable = true
        inspector.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        inspector.backgroundColor = NSColor.windowBackgroundColor
        inspector.textContainerInset = NSSize(width: 8, height: 6)
        let inspectorScroll = NSScrollView()
        inspectorScroll.hasVerticalScroller = true
        inspectorScroll.documentView = inspector

        let toolbar = makeToolbar()
        [toolbar, splitView, inspectorScroll].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            toolbar.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            toolbar.heightAnchor.constraint(equalToConstant: 30),

            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            splitView.bottomAnchor.constraint(equalTo: inspectorScroll.topAnchor, constant: -8),

            inspectorScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inspectorScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inspectorScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            inspectorScroll.heightAnchor.constraint(equalToConstant: 126),
        ])

        scenarioPopup.addItems(withTitles: store.scenarios.map { $0.title })
        scenarioPopup.target = self
        scenarioPopup.action = #selector(scenarioChanged(_:))
        rendererPopup.addItems(withTitles: ["Core Graphics", "Metal"])
        rendererPopup.target = self
        rendererPopup.action = #selector(rendererChanged(_:))
        policyPopup.addItems(withTitles: ["Respect terminal", "Legacy LTR"])
        policyPopup.target = self
        policyPopup.action = #selector(policyChanged(_:))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !didInstallInitialScenario, let first = store.scenarios.first else { return }
        didInstallInitialScenario = true
        do {
            try loadScenario(first.id)
        } catch {
            inspector.string = "Could not load the initial scenario: \(error)"
        }
    }

    private func makeToolbar() -> NSView {
        let previous = button("Previous", #selector(previousStep(_:)))
        let next = button("Next", #selector(nextStep(_:)))
        let reset = button("Reset", #selector(resetScenarioAction(_:)))
        let applySize = button("Resize", #selector(resizeAction(_:)))
        let top = button("Top", #selector(scrollTopAction(_:)))
        let bottom = button("Bottom", #selector(scrollBottomAction(_:)))
        let capture = button("Capture", #selector(captureAction(_:)))

        colsField.alignment = .right
        rowsField.alignment = .right
        colsField.toolTip = "Terminal columns"
        rowsField.toolTip = "Terminal rows"
        colsField.widthAnchor.constraint(equalToConstant: 42).isActive = true
        rowsField.widthAnchor.constraint(equalToConstant: 36).isActive = true
        scenarioPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        rendererPopup.widthAnchor.constraint(equalToConstant: 112).isActive = true
        policyPopup.widthAnchor.constraint(equalToConstant: 126).isActive = true

        let stack = NSStackView(views: [
            scenarioPopup, previous, next, reset, stepLabel,
            separator(), colsField, NSTextField(labelWithString: "×"), rowsField, applySize,
            separator(), top, bottom, rendererPopup, policyPopup, capture,
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        box.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return box
    }

    @objc private func scenarioChanged(_ sender: Any?) {
        let index = scenarioPopup.indexOfSelectedItem
        guard store.scenarios.indices.contains(index) else { return }
        do {
            try loadScenario(store.scenarios[index].id)
        } catch {
            present(error)
        }
    }

    @objc private func previousStep(_ sender: Any?) {
        do { _ = try gotoStep(max(-1, currentStepIndex - 1)) } catch { present(error) }
    }

    @objc private func nextStep(_ sender: Any?) {
        guard let scenario = currentScenario else { return }
        do { _ = try gotoStep(min(scenario.steps.count - 1, currentStepIndex + 1)) } catch { present(error) }
    }

    @objc private func resetScenarioAction(_ sender: Any?) {
        do { try resetCurrentScenario() } catch { present(error) }
    }

    @objc private func resizeAction(_ sender: Any?) {
        guard let cols = Int(colsField.stringValue), let rows = Int(rowsField.stringValue) else { return }
        do { try resizeTerminal(cols: cols, rows: rows) } catch { present(error) }
    }

    @objc private func scrollTopAction(_ sender: Any?) {
        terminalView.scroll(toPosition: 0)
        updateInspector()
    }

    @objc private func scrollBottomAction(_ sender: Any?) {
        terminalView.scroll(toPosition: 1)
        updateInspector()
    }

    @objc private func rendererChanged(_ sender: Any?) {
        do { try setRenderer(rendererPopup.indexOfSelectedItem == 1 ? "metal" : "coreGraphics") } catch { present(error) }
    }

    @objc private func policyChanged(_ sender: Any?) {
        setHostPolicy(policyPopup.indexOfSelectedItem == 1 ? "legacyLeftToRight" : "respectTerminal")
    }

    @objc private func captureAction(_ sender: Any?) {
        do { _ = try capture(name: currentStepName) } catch { present(error) }
    }

    private func present(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window = view.window {
            alert.beginSheetModal(for: window)
        }
        updateInspector(extra: "Error: \(error)")
    }

    var currentStepName: String {
        guard let scenario = currentScenario else { return "manual" }
        guard scenario.steps.indices.contains(currentStepIndex) else { return "00-setup" }
        return String(format: "%02d-%@", currentStepIndex + 1, scenario.steps[currentStepIndex].id)
    }

    func handle(_ command: HarnessCommand) throws -> Any {
        let result = try execute(command)
        updateInspector()
        return result
    }

    @discardableResult
    private func execute(_ request: HarnessCommand) throws -> Any {
        let arguments = request.arguments
        switch request.command {
        case "ping":
            return ["version": 1, "runID": runID, "pid": ProcessInfo.processInfo.processIdentifier]
        case "status":
            return statusDictionary()
        case "listScenarios":
            return store.scenarios.map {
                ["id": $0.id, "title": $0.title, "purpose": $0.purpose, "steps": $0.steps.count] as [String: Any]
            }
        case "loadScenario":
            guard let id = arguments.string("scenario") else { throw HarnessError.invalidArgument("loadScenario requires scenario") }
            try loadScenario(id)
            return statusDictionary()
        case "gotoStep":
            if let index = arguments.int("step") {
                return try gotoStep(index)
            }
            if let id = arguments.string("step"), let scenario = currentScenario,
               let index = scenario.steps.firstIndex(where: { $0.id == id }) {
                return try gotoStep(index)
            }
            throw HarnessError.invalidArgument("gotoStep requires a valid numeric index or step identifier")
        case "nextStep":
            guard let scenario = currentScenario else { throw HarnessError.invalidScenario("No scenario is loaded") }
            return try gotoStep(min(scenario.steps.count - 1, currentStepIndex + 1))
        case "resetScenario":
            try resetCurrentScenario()
            return statusDictionary()
        case "feed":
            guard let text = arguments.string("text") else { throw HarnessError.invalidArgument("feed requires text") }
            terminalView.feed(text: text)
            return ["bytes": text.utf8.count]
        case "feedBase64":
            guard let encoded = arguments.string("data"), let data = Data(base64Encoded: encoded) else {
                throw HarnessError.invalidArgument("feedBase64 requires valid Base64 data")
            }
            terminalView.feed(byteArray: Array(data)[...])
            return ["bytes": data.count]
        case "feedFixture":
            guard let name = arguments.string("fixture") else { throw HarnessError.invalidArgument("feedFixture requires fixture") }
            let fixture = try store.fixture(named: name)
            terminalView.feed(text: fixture)
            return ["bytes": fixture.utf8.count]
        case "resize":
            guard let cols = arguments.int("cols"), let rows = arguments.int("rows") else {
                throw HarnessError.invalidArgument("resize requires integer cols and rows")
            }
            try resizeTerminal(cols: cols, rows: rows)
            return ["cols": cols, "rows": rows]
        case "scrollToRow":
            guard let row = arguments.int("row") else { throw HarnessError.invalidArgument("scrollToRow requires row") }
            terminalView.scrollTo(row: row)
            return statusDictionary()
        case "scrollBy":
            guard let rows = arguments.int("rows") else { throw HarnessError.invalidArgument("scrollBy requires rows") }
            if rows < 0 { terminalView.scrollUp(lines: -rows) } else { terminalView.scrollDown(lines: rows) }
            return statusDictionary()
        case "scrollToEdge":
            guard let edge = arguments.string("edge"), edge == "top" || edge == "bottom" else {
                throw HarnessError.invalidArgument("scrollToEdge requires top or bottom")
            }
            terminalView.scroll(toPosition: edge == "top" ? 0 : 1)
            return statusDictionary()
        case "setCursor":
            guard let row = arguments.int("row"), let col = arguments.int("col"), row >= 0, col >= 0 else {
                throw HarnessError.invalidArgument("setCursor requires zero-based row and col")
            }
            terminalView.feed(text: "\u{1b}[\(row + 1);\(col + 1)H")
            return statusDictionary()
        case "setRenderer":
            guard let renderer = arguments.string("renderer") else { throw HarnessError.invalidArgument("setRenderer requires renderer") }
            try setRenderer(renderer)
            return ["renderer": rendererName]
        case "setHostPolicy":
            guard let policy = arguments.string("policy") else { throw HarnessError.invalidArgument("setHostPolicy requires policy") }
            setHostPolicy(policy)
            return ["hostPolicy": hostPolicyName]
        case "setCustomBlockGlyphs":
            guard let enabled = arguments.bool("enabled") else { throw HarnessError.invalidArgument("setCustomBlockGlyphs requires enabled") }
            terminalView.customBlockGlyphs = enabled
            terminalView.needsDisplay = true
            return ["enabled": enabled]
        case "setFont":
            let name = arguments.string("name") ?? terminalView.font.fontName
            let size = arguments.double("size") ?? Double(terminalView.font.pointSize)
            guard size >= 6, size <= 72, let font = NSFont(name: name, size: size) else {
                throw HarnessError.invalidArgument("The font name or size is invalid")
            }
            terminalView.font = font
            let dims = terminalView.terminal.getDims()
            try resizeTerminal(cols: dims.cols, rows: dims.rows)
            return ["name": terminalView.font.fontName, "size": terminalView.font.pointSize]
        case "changeScrollback":
            guard let lines = arguments.int("lines"), lines >= 0 else { throw HarnessError.invalidArgument("changeScrollback requires a nonnegative line count") }
            terminalView.changeScrollback(lines)
            return ["lines": lines]
        case "softReset":
            terminalView.feed(text: "\u{1b}[!p")
            return statusDictionary()
        case "hardReset":
            terminalView.feed(text: "\u{1b}c")
            return statusDictionary()
        case "key":
            guard let key = arguments.string("key") else { throw HarnessError.invalidArgument("key requires a key name") }
            outgoingBytes.removeAll()
            try sendKey(key)
            return ["outgoingBase64": outgoingBytes.base64EncodedString()]
        case "click":
            guard let point = arguments.object("at"), let column = point.int("column"), let row = point.int("row") else {
                throw HarnessError.invalidArgument("click requires at.column and at.row")
            }
            try click(column: column, row: row)
            return ["selection": terminalView.getSelection() as Any]
        case "drag":
            guard let from = arguments.object("from"), let to = arguments.object("to"),
                  let fromColumn = from.int("column"), let fromRow = from.int("row"),
                  let toColumn = to.int("column"), let toRow = to.int("row") else {
                throw HarnessError.invalidArgument("drag requires from and to cell coordinates")
            }
            try drag(fromColumn: fromColumn, fromRow: fromRow, toColumn: toColumn, toRow: toRow)
            return ["selection": terminalView.getSelection() as Any]
        case "moveWindow":
            guard let x = arguments.double("x"), let y = arguments.double("y"), let window = view.window else {
                throw HarnessError.invalidArgument("moveWindow requires x and y")
            }
            window.setFrameOrigin(NSPoint(x: x, y: y))
            return ["x": window.frame.origin.x, "y": window.frame.origin.y]
        case "capture":
            return try capture(name: arguments.string("name") ?? currentStepName)
        case "runSuite":
            let requestedScenarios: [String]
            if case .array(let values) = arguments["scenarios"] {
                requestedScenarios = values.compactMap { if case .string(let value) = $0 { return value }; return nil }
            } else {
                requestedScenarios = store.scenarios.map(\.id)
            }
            let requestedRenderers: [String]
            if case .array(let values) = arguments["renderers"] {
                requestedRenderers = values.compactMap { if case .string(let value) = $0 { return value }; return nil }
            } else {
                requestedRenderers = ["coreGraphics", "metal"]
            }
            return try runSuite(scenarios: requestedScenarios, renderers: requestedRenderers)
        case "quit":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { NSApplication.shared.terminate(nil) }
            return ["quitting": true]
        default:
            throw HarnessError.invalidCommand("Unknown command: \(request.command)")
        }
    }

    private func loadScenario(_ id: String) throws {
        let scenario = try store.scenario(id: id)
        currentScenario = scenario
        currentStepIndex = -1
        actionTimingsMilliseconds.removeAll()
        if let index = store.scenarios.firstIndex(where: { $0.id == id }) {
            scenarioPopup.selectItem(at: index)
        }
        try loadReference(scenario)
        try applyInitialState(scenario.initial)
        for (index, action) in scenario.setup.enumerated() {
            try executeTimed(action, label: "setup.\(index).\(action.command)")
        }
        lastAssertionResults = []
        updateStepLabel()
        updateInspector()
    }

    private func resetCurrentScenario() throws {
        guard let scenario = currentScenario else { throw HarnessError.invalidScenario("No scenario is loaded") }
        try loadScenario(scenario.id)
    }

    private func gotoStep(_ requestedIndex: Int) throws -> Any {
        guard let scenario = currentScenario else { throw HarnessError.invalidScenario("No scenario is loaded") }
        guard requestedIndex >= -1, requestedIndex < scenario.steps.count else {
            throw HarnessError.invalidArgument("Step index is out of range")
        }
        try loadScenario(scenario.id)
        if requestedIndex >= 0 {
            for index in 0...requestedIndex {
                for (actionIndex, action) in scenario.steps[index].actions.enumerated() {
                    try executeTimed(
                        action,
                        label: "\(scenario.steps[index].id).\(actionIndex).\(action.command)"
                    )
                }
            }
            currentStepIndex = requestedIndex
            let step = scenario.steps[requestedIndex]
            try loadReference(scenario, reference: step.reference ?? scenario.reference,
                              detail: step.title, lineCount: step.referenceLineCount)
            lastAssertionResults = runAssertions(scenario.steps[requestedIndex].assertions)
        }
        updateStepLabel()
        updateInspector()
        return statusDictionary()
    }

    private func applyInitialState(_ initial: ScenarioInitialState) throws {
        guard let font = NSFont(name: initial.fontName, size: initial.fontSize) else {
            throw HarnessError.invalidScenario("Font not found: \(initial.fontName)")
        }
        terminalView.font = font
        terminalView.terminal.options.scrollback = initial.scrollback
        // The harness feeds application output directly, without a PTY's
        // output post-processing. Match the usual PTY behavior: LF also
        // returns the cursor to column zero.
        terminalView.terminal.options.convertEol = true
        terminalView.terminal.options.maximumBidiParagraphRows = initial.maximumBidiParagraphRows
        terminalView.terminal.options.initialBidiState = .default
        terminalView.terminal.options.initialBidiArrowKeySwap = true
        terminalView.feed(text: "\u{1b}c")
        terminalView.changeScrollback(initial.scrollback)
        terminalView.customBlockGlyphs = initial.customBlockGlyphs
        setHostPolicy(initial.hostPolicy)
        try setRenderer(initial.renderer)
        try resizeTerminal(cols: initial.cols, rows: initial.rows)
        outgoingBytes.removeAll()
    }

    private func executeTimed(_ command: HarnessCommand, label: String) throws {
        let start = CFAbsoluteTimeGetCurrent()
        _ = try execute(command)
        actionTimingsMilliseconds[label] = (CFAbsoluteTimeGetCurrent() - start) * 1_000
    }

    private func resizeTerminal(cols: Int, rows: Int) throws {
        guard (1...500).contains(cols), (1...300).contains(rows) else {
            throw HarnessError.invalidArgument("Terminal dimensions are outside the supported harness range")
        }
        terminalView.resize(cols: cols, rows: rows)
        colsField.stringValue = String(cols)
        rowsField.stringValue = String(rows)
        resizeWindowToTerminal()
        let finalDimensions = terminalView.terminal.getDims()
        if finalDimensions.cols != cols || finalDimensions.rows != rows {
            terminalView.resize(cols: cols, rows: rows)
        }
        settleDisplay()
    }

    private func resizeWindowToTerminal() {
        guard let window = view.window else { return }
        let terminalSize = terminalView.getOptimalFrameSize().size
        let contentWidth = max(320, terminalSize.width * 2 + splitView.dividerThickness)
        let contentHeight = max(420, terminalSize.height + 172)
        window.setContentSize(NSSize(width: contentWidth, height: contentHeight))
        view.layoutSubtreeIfNeeded()
        splitView.adjustSubviews()
        splitView.setPosition(splitView.bounds.width / 2, ofDividerAt: 0)
    }

    private func setRenderer(_ renderer: String) throws {
        switch renderer {
        case "coreGraphics":
            try terminalView.setUseMetal(false)
            rendererPopup.selectItem(at: 0)
        case "metal":
            try terminalView.setUseMetal(true)
            rendererPopup.selectItem(at: 1)
        default:
            throw HarnessError.invalidArgument("Renderer must be coreGraphics or metal")
        }
        terminalView.needsDisplay = true
        settleDisplay()
    }

    private func setHostPolicy(_ policy: String) {
        if policy == "legacyLeftToRight" {
            terminalView.bidiHostPolicy = .legacyLeftToRight
            policyPopup.selectItem(at: 1)
        } else {
            terminalView.bidiHostPolicy = .respectTerminal
            policyPopup.selectItem(at: 0)
        }
        terminalView.needsDisplay = true
    }

    private var rendererName: String { terminalView.isUsingMetalRenderer ? "metal" : "coreGraphics" }
    private var hostPolicyName: String { terminalView.bidiHostPolicy == .respectTerminal ? "respectTerminal" : "legacyLeftToRight" }

    private func sendKey(_ name: String) throws {
        let definition: (UInt16, unichar)
        switch name {
        case "left": definition = (123, unichar(NSLeftArrowFunctionKey))
        case "right": definition = (124, unichar(NSRightArrowFunctionKey))
        case "home": definition = (115, unichar(NSHomeFunctionKey))
        case "end": definition = (119, unichar(NSEndFunctionKey))
        default: throw HarnessError.invalidArgument("Supported keys are left, right, home, and end")
        }
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            characters: String(UnicodeScalar(definition.1)!),
            charactersIgnoringModifiers: String(UnicodeScalar(definition.1)!),
            isARepeat: false,
            keyCode: definition.0
        ) else { throw HarnessError.io("Could not create a key event") }
        terminalView.keyDown(with: event)
    }

    private func cellPoint(column: Int, row: Int) throws -> NSPoint {
        let dims = terminalView.terminal.getDims()
        guard column >= 0, column < dims.cols, row >= 0, row < dims.rows else {
            throw HarnessError.invalidArgument("Cell coordinate is outside the visible terminal")
        }
        let cellSize = terminalView.caretFrame.size
        return NSPoint(
            x: (CGFloat(column) + 0.5) * cellSize.width,
            y: terminalView.bounds.height - (CGFloat(row) + 0.5) * cellSize.height
        )
    }

    private func mouseEvent(type: NSEvent.EventType, point: NSPoint, eventNumber: Int) throws -> NSEvent {
        guard let window = view.window else { throw HarnessError.io("The harness window is unavailable") }
        let windowPoint = terminalView.convert(point, to: nil)
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ) else { throw HarnessError.io("Could not create a mouse event") }
        return event
    }

    private func click(column: Int, row: Int) throws {
        let point = try cellPoint(column: column, row: row)
        terminalView.mouseDown(with: try mouseEvent(type: .leftMouseDown, point: point, eventNumber: 1))
        terminalView.mouseUp(with: try mouseEvent(type: .leftMouseUp, point: point, eventNumber: 2))
        settleDisplay()
    }

    private func drag(fromColumn: Int, fromRow: Int, toColumn: Int, toRow: Int) throws {
        let start = try cellPoint(column: fromColumn, row: fromRow)
        let end = try cellPoint(column: toColumn, row: toRow)
        terminalView.mouseDown(with: try mouseEvent(type: .leftMouseDown, point: start, eventNumber: 3))
        terminalView.mouseDragged(with: try mouseEvent(type: .leftMouseDragged, point: end, eventNumber: 4))
        terminalView.mouseUp(with: try mouseEvent(type: .leftMouseUp, point: end, eventNumber: 5))
        settleDisplay()
    }

    private func escapedHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func loadReference(_ scenario: HarnessScenario,
                               reference: ScenarioReference? = nil,
                               detail: String? = nil,
                               lineCount: Int? = nil) throws {
        let reference = reference ?? scenario.reference
        let body: String
        if let lines = reference.lines {
            let requestedLineCount = lineCount ?? (detail == nil ? reference.initialLineCount : nil)
            let visibleLines = requestedLineCount.map { Array(lines.prefix(max(0, $0))) } ?? lines
            body = visibleLines.map { line in
                let direction = ["ltr", "rtl", "auto"].contains(line.direction)
                    ? line.direction : "auto"
                let alignment = ["left", "right"].contains(line.alignment)
                    ? line.alignment : "start"
                if line.mode == "visual" {
                    return "<div class=\"reference-line visual\" dir=\"ltr\" style=\"text-align: \(alignment)\">\(escapedHTML(line.text))</div>"
                }
                let unicodeBidi = direction == "auto" ? "plaintext" : "isolate"
                return "<div class=\"reference-line\" dir=\"\(direction)\" style=\"text-align: \(alignment); unicode-bidi: \(unicodeBidi)\">\(escapedHTML(line.text))</div>"
            }.joined(separator: "\n")
        } else {
            let text = try store.referenceText(for: reference)
            let direction = ["ltr", "rtl", "auto"].contains(reference.direction)
                ? reference.direction : "auto"
            body = "<pre dir=\"\(direction)\">\(escapedHTML(text))</pre>"
        }
        let referenceTitle = detail.map { "\(scenario.title) — \($0)" } ?? scenario.title
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
        :root { color-scheme: dark; }
        body { margin: 0; padding: 12px; background: #0f0f0f; color: #ededed;
               font: 14px Menlo, ui-monospace, monospace; }
        .label { position: sticky; top: 0; padding: 3px 6px; margin: -4px -4px 10px;
                 background: #252525; color: #aaa; font: 11px -apple-system, sans-serif; }
        pre { margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; unicode-bidi: plaintext; }
        .reference-line { white-space: pre-wrap; overflow-wrap: anywhere; min-height: 1.2em; }
        .visual { direction: ltr; unicode-bidi: bidi-override; }
        </style></head><body><div class="label">WebKit reference — \(escapedHTML(referenceTitle))</div>
        \(body)</body></html>
        """
        referenceLoadPending = true
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func visibleRows() -> [VisibleRowManifest] {
        let terminal = terminalView.terminal!
        let dims = terminal.getDims()
        return (0..<dims.rows).compactMap { row in
            guard let line = terminal.getLine(row: row) else { return nil }
            let text = line
                .translateToString(trimRight: true, characterProvider: terminal.getCharacter(for:))
                .replacingOccurrences(of: "\0", with: " ")
            return VisibleRowManifest(
                row: row,
                text: text,
                isWrapped: line.isWrapped,
                bidiState: bidiStateName(line.bidiState)
            )
        }
    }

    private func logicalBufferText() -> String {
        String(data: terminalView.terminal.getBufferAsData(), encoding: .utf8) ?? ""
    }

    private func statusDictionary() -> [String: Any] {
        let terminal = terminalView.terminal!
        let dims = terminal.getDims()
        let cursor = terminal.getCursorLocation()
        return [
            "scenario": currentScenario?.id as Any,
            "step": currentStepIndex,
            "stepID": currentScenario?.steps.indices.contains(currentStepIndex) == true ? currentScenario!.steps[currentStepIndex].id : NSNull(),
            "cols": dims.cols,
            "rows": dims.rows,
            "cursor": ["column": cursor.x, "row": cursor.y],
            "viewportRow": terminal.buffer.yDisp,
            "scrollPosition": terminalView.scrollPosition,
            "renderer": rendererName,
            "hostPolicy": hostPolicyName,
            "currentBidiState": bidiStateName(terminal.currentBidiState),
            "arrowKeySwap": terminal.bidiArrowKeySwap,
            "customBlockGlyphs": terminalView.customBlockGlyphs,
            "terminalFrame": ["x": terminalView.frame.origin.x, "y": terminalView.frame.origin.y, "width": terminalView.frame.width, "height": terminalView.frame.height],
            "referenceFrame": ["x": webView.frame.origin.x, "y": webView.frame.origin.y, "width": webView.frame.width, "height": webView.frame.height],
            "referenceLoading": referenceLoadPending || webView.isLoading,
            "referenceURL": webView.url?.absoluteString as Any,
            "selection": terminalView.getSelection() as Any,
            "outgoingBase64": outgoingBytes.base64EncodedString(),
            "visibleRows": visibleRows().map {
                ["row": $0.row, "text": $0.text, "isWrapped": $0.isWrapped, "bidiState": $0.bidiState] as [String: Any]
            },
            "assertions": lastAssertionResults.map { ["kind": $0.kind, "passed": $0.passed, "message": $0.message] },
            "timingsMilliseconds": actionTimingsMilliseconds,
        ]
    }

    private func runAssertions(_ assertions: [ScenarioAssertion]) -> [AssertionResult] {
        let terminal = terminalView.terminal!
        let dims = terminal.getDims()
        let visibleText = visibleRows().map(\.text).joined(separator: "\n")
        return assertions.map { assertion in
            let passed: Bool
            let actual: String
            switch assertion.kind {
            case "dimensions":
                let expectedCols = assertion.arguments.int("cols")
                let expectedRows = assertion.arguments.int("rows")
                passed = dims.cols == expectedCols && dims.rows == expectedRows
                actual = "actual=\(dims.cols)x\(dims.rows)"
            case "currentMode":
                let mode = bidiStateName(terminal.currentBidiState)
                passed = mode == assertion.arguments.string("mode")
                actual = "actual=\(mode)"
            case "arrowKeySwap":
                passed = terminal.bidiArrowKeySwap == assertion.arguments.bool("enabled")
                actual = "actual=\(terminal.bidiArrowKeySwap)"
            case "visibleContains":
                let text = assertion.arguments.string("text") ?? ""
                passed = visibleText.contains(text)
                actual = passed ? "text found" : "text not found"
            case "wrappedRowCountAtLeast":
                let expected = assertion.arguments.int("count") ?? 0
                let count = visibleRows().filter(\.isWrapped).count
                passed = count >= expected
                actual = "actual=\(count)"
            case "selectionEquals":
                let selection = terminalView.getSelection() ?? ""
                passed = selection == assertion.arguments.string("text")
                actual = "actual=\(selection)"
            case "outgoingBase64":
                let encoded = outgoingBytes.base64EncodedString()
                passed = encoded == assertion.arguments.string("data")
                actual = "actual=\(encoded)"
            default:
                passed = false
                actual = "unsupported assertion"
            }
            return AssertionResult(kind: assertion.kind, passed: passed, message: actual)
        }
    }

    private func capture(name: String) throws -> [String: Any] {
        guard let window = view.window, let scenario = currentScenario else {
            throw HarnessError.captureUnavailable("The harness window or scenario is unavailable")
        }
        if scenario.steps.indices.contains(currentStepIndex) {
            lastAssertionResults = runAssertions(scenario.steps[currentStepIndex].assertions)
        }
        updateInspector()
        settleDisplay()
        let png = try ArtifactCapture.captureWindow(
            window,
            terminalView: terminalView,
            webView: webView,
            referenceFallback: try makeReferenceFallbackImage(for: scenario)
        )
        let terminal = terminalView.terminal!
        let dims = terminal.getDims()
        let cursor = terminal.getCursorLocation()
        let logicalText = logicalBufferText()
        let manifest = HarnessManifest(
            runID: runID,
            scenario: scenario.id,
            step: name,
            renderer: rendererName,
            gitRevision: ProcessInfo.processInfo.environment["SWIFTTERM_GIT_SHA"] ?? "unknown",
            capturedAt: ISO8601DateFormatter().string(from: Date()),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            backingScale: Double(window.backingScaleFactor),
            fontName: terminalView.font.fontName,
            fontSize: Double(terminalView.font.pointSize),
            cols: dims.cols,
            rows: dims.rows,
            cursorColumn: cursor.x,
            cursorRow: cursor.y,
            viewportRow: terminal.buffer.yDisp,
            scrollPosition: terminalView.scrollPosition,
            currentBidiState: bidiStateName(terminal.currentBidiState),
            arrowKeySwap: terminal.bidiArrowKeySwap,
            hostPolicy: hostPolicyName,
            customBlockGlyphs: terminalView.customBlockGlyphs,
            selection: terminalView.getSelection(),
            outgoingBytesBase64: outgoingBytes.base64EncodedString(),
            logicalBufferSHA256: ArtifactCapture.sha256(logicalText),
            visibleRows: visibleRows(),
            assertions: lastAssertionResults,
            timingsMilliseconds: actionTimingsMilliseconds,
            imagePath: ""
        )
        let result = try ArtifactCapture.write(pngData: png, logicalText: logicalText, manifest: manifest, root: artifactRoot)
        return [
            "image": result.imageURL.path,
            "manifest": result.manifestURL.path,
            "logicalBuffer": result.logicalBufferURL.path,
            "assertionsPassed": result.manifest.assertions.allSatisfy(\.passed),
        ]
    }

    private func runSuite(scenarios: [String], renderers: [String]) throws -> [String: Any] {
        var captures: [[String: Any]] = []
        for scenarioID in scenarios {
            let scenario = try store.scenario(id: scenarioID)
            for renderer in renderers {
                try loadScenario(scenario.id)
                try setRenderer(renderer)
                for index in scenario.steps.indices where scenario.steps[index].capture {
                    _ = try gotoStep(index)
                    try setRenderer(renderer)
                    captures.append(try capture(name: currentStepName))
                }
            }
        }
        return ["captures": captures, "count": captures.count, "artifactRoot": artifactRoot.path]
    }

    private func makeReferenceFallbackImage(for scenario: HarnessScenario) throws -> NSImage {
        let text = try store.referenceText(for: scenario)
        let size = webView.bounds.size
        guard size.width > 0, size.height > 0 else {
            throw HarnessError.captureUnavailable("The reference pane has no drawable area")
        }
        let style = NSMutableParagraphStyle()
        switch scenario.reference.direction {
        case "rtl": style.baseWritingDirection = .rightToLeft
        case "ltr": style.baseWritingDirection = .leftToRight
        default: style.baseWritingDirection = .natural
        }
        let body = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont(name: "Menlo", size: 14) ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                .foregroundColor: NSColor(calibratedWhite: 0.93, alpha: 1),
                .paragraphStyle: style,
            ]
        )
        let label = NSAttributedString(
            string: "Reference fallback — WebKit snapshot unavailable",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor(calibratedWhite: 0.65, alpha: 1),
            ]
        )
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        NSColor(calibratedWhite: 0.06, alpha: 1).setFill()
        NSBezierPath.fill(NSRect(origin: .zero, size: size))
        label.draw(at: NSPoint(x: 12, y: 8))
        body.draw(
            with: NSRect(x: 12, y: 34, width: max(0, size.width - 24), height: max(0, size.height - 42)),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        image.unlockFocus()
        return image
    }

    private func settleDisplay() {
        let webDeadline = Date(timeIntervalSinceNow: 2)
        while (referenceLoadPending || webView.isLoading), Date() < webDeadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        view.layoutSubtreeIfNeeded()
        terminalView.needsDisplay = true
        terminalView.displayIfNeeded()
        webView.displayIfNeeded()
        CATransaction.flush()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.025))
        view.layoutSubtreeIfNeeded()
        terminalView.displayIfNeeded()
        CATransaction.flush()
        if terminalView.isUsingMetalRenderer {
            // The MTKView submits its command buffer asynchronously. Give the
            // WindowServer time to receive the presented drawable before a
            // capture helper asks for the window image.
            terminalView.drawMetalFrameNow()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
            terminalView.drawMetalFrameNow()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            CATransaction.flush()
        }
    }

    private func updateStepLabel() {
        if let scenario = currentScenario, scenario.steps.indices.contains(currentStepIndex) {
            stepLabel.stringValue = "\(currentStepIndex + 1)/\(scenario.steps.count): \(scenario.steps[currentStepIndex].title)"
        } else {
            stepLabel.stringValue = "Setup"
        }
    }

    private func updateInspector(extra: String? = nil) {
        guard isViewLoaded, terminalView.terminal != nil else { return }
        var status = statusDictionary()
        if let extra { status["message"] = extra }
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            inspector.string = string
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let isLocalDocument = navigationAction.request.url == nil || navigationAction.request.url?.scheme == "about"
        if navigationAction.navigationType == .other && isLocalDocument {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        referenceLoadPending = false
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        referenceLoadPending = false
        updateInspector(extra: "WebKit reference load failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        referenceLoadPending = false
        updateInspector(extra: "WebKit reference load failed: \(error.localizedDescription)")
    }

    // MARK: TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        colsField.stringValue = String(newCols)
        rowsField.stringValue = String(newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        outgoingBytes.append(contentsOf: data)
        updateInspector()
    }

    func scrolled(source: TerminalView, position: Double) { updateInspector() }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) { updateInspector() }
}
