#if os(iOS) || os(visionOS)
import SwiftTerm
import Testing
import UIKit

// Deliberately use a regular import: hosts must be able to override these
// hooks without access to SwiftTerm's internal selection or gesture objects.
@MainActor
@Suite("iOS selection UI hooks", .serialized)
struct IOSSelectionUIHooksTests {
    @Test func customPresentationPreservesSelectAtTheRequestedPoint() async throws {
        let view = try await makeView()
        let point = CGPoint(x: view.caretFrame.width / 2, y: view.caretFrame.height / 2)

        view.showStandardContextMenu(at: point)

        #expect(view.presentedRegions.count == 1)
        #expect(view.presentedRegions[0].origin == point)
        #expect(view.canPerformAction(#selector(view.select(_:)), withSender: nil))
        view.select(nil)
        #expect(view.getSelection() == "alpha")
        // Select presents a menu asynchronously after establishing the selection.
        for _ in 0..<100 where view.presentedRegions.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(view.presentedRegions.count == 2)
        #expect(view.presentedSelections.last == "alpha")
        #expect(view.canPerformAction(#selector(view.copy(_:)), withSender: nil))
    }

    @Test func customActionsCanExtendTheStandardActionFilter() async throws {
        let view = try await makeView()
        let custom = #selector(HostTerminal.useSelection(_:))
        #expect(!view.canPerformAction(custom, withSender: nil))
        #expect(view.canPerformAction(#selector(view.paste(_:)), withSender: nil))

        view.setSelectionRange(start: Position(col: 0, row: 0), end: Position(col: 5, row: 0))

        #expect(view.canPerformAction(custom, withSender: nil))
        #expect(view.canPerformAction(#selector(view.copy(_:)), withSender: nil))
        view.useSelection(nil)
        #expect(view.actionText == "alpha")
    }

    @Test(arguments: [UIGestureRecognizer.State.ended, .cancelled])
    func dragOverrideKeepsSelectionBehaviorAndReceivesLifecycle(ending: UIGestureRecognizer.State) async throws {
        let view = try await makeView()
        view.setSelectionRange(start: Position(col: 0, row: 0), end: Position(col: 5, row: 0))
        let gesture = PositionedPan()
        let cell = view.caretFrame.size
        gesture.point = CGPoint(x: cell.width * 5.5, y: cell.height / 2)
        gesture.simulatedState = .began
        view.perform(#selector(TerminalView.panSelectionHandler(_:)), with: gesture)
        gesture.point.x = cell.width * 10.5
        gesture.simulatedState = .changed
        view.perform(#selector(TerminalView.panSelectionHandler(_:)), with: gesture)

        #expect(view.getSelection() == "alpha beta")
        #expect(view.dragStates == [.began, .changed])
        #expect(view.dragPoints.last == gesture.point)

        gesture.simulatedState = ending
        view.perform(#selector(TerminalView.panSelectionHandler(_:)), with: gesture)

        #expect(view.dragStates == [.began, .changed, ending])
        #expect(view.hasActiveSelection == (ending == .ended))
        #expect(view.presentedRegions.count == (ending == .ended ? 1 : 0))
    }

    @Test func defaultMenuStillClearsCustomItemsAndUsesStandardActions() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        let controller = UIMenuController.shared
        let previousItems = controller.menuItems
        defer {
            controller.hideMenu()
            controller.menuItems = previousItems
        }
        controller.menuItems = [UIMenuItem(title: "Stale", action: #selector(HostTerminal.useSelection(_:)))]

        view.showStandardContextMenu(at: CGPoint(x: 8, y: 8))

        #expect(controller.menuItems?.isEmpty != false)
        #expect(!view.canPerformAction(#selector(view.copy(_:)), withSender: nil))
        #expect(view.canPerformAction(#selector(view.select(_:)), withSender: nil))
        #expect(view.canPerformAction(#selector(view.paste(_:)), withSender: nil))
        #expect(view.canPerformAction(#selector(view.selectAll(_:)), withSender: nil))
        #expect(!view.canPerformAction(#selector(HostTerminal.useSelection(_:)), withSender: nil))
    }

    private func makeView() async throws -> HostTerminal {
        let view = HostTerminal(
            frame: CGRect(x: 0, y: 0, width: 640, height: 320),
            options: TerminalOptions(cols: 40, rows: 10)
        )
        view.feed(text: "alpha beta")
        for _ in 0..<300 {
            if String(data: view.getBufferAsData(), encoding: .utf8)?.contains("alpha beta") == true {
                return view
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The view did not parse the fixture output")
        return view
    }

    private final class HostTerminal: TerminalView {
        var presentedRegions: [CGRect] = []
        var presentedSelections: [String?] = []
        var dragStates: [UIGestureRecognizer.State] = []
        var dragPoints: [CGPoint] = []
        var actionText: String?

        override func presentContextMenu(forRegion region: CGRect) {
            presentedRegions.append(region)
            presentedSelections.append(getSelection())
        }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(useSelection(_:)) { return hasActiveSelection }
            return super.canPerformAction(action, withSender: sender)
        }

        @objc func useSelection(_ sender: Any?) {
            actionText = getSelection()
        }

        override func panSelectionHandler(_ gestureRecognizer: UIPanGestureRecognizer) {
            super.panSelectionHandler(gestureRecognizer)
            dragStates.append(gestureRecognizer.state)
            dragPoints.append(gestureRecognizer.location(in: self))
        }
    }

    private final class PositionedPan: UIPanGestureRecognizer {
        var simulatedState: UIGestureRecognizer.State = .possible
        var point: CGPoint = .zero
        override var state: UIGestureRecognizer.State {
            get { simulatedState }
            set { simulatedState = newValue }
        }
        override func location(in view: UIView?) -> CGPoint { point }
    }
}
#endif
