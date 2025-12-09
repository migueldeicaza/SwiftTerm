#if canImport(UIKit) && DEBUG
import SwiftUI

// Internal, for testing - look at SwiftTermApp for a proper binding
@available(iOS 13.0, *)
@available(visionOS 1.0, *)
struct SwiftUITerminalView: View {
    /// Optional closure that is invoked once right after the underlying ``TerminalView`` is created.
    /// Use this to seed data via `feed` or to tweak the instance before it appears.
    private let startupFeed: ((TerminalView) -> Void)?

    public init(startupFeed: ((TerminalView) -> Void)? = nil) {
        self.startupFeed = startupFeed
    }

    public var body: some View {
        TerminalViewContainer(startupFeed: startupFeed)
    }
}

@available(iOS 13.0, *)
@available(visionOS 1.0, *)
private struct TerminalViewContainer: UIViewRepresentable {
    typealias UIViewType = SwiftUITerminalHostView

    var startupFeed: ((TerminalView) -> Void)?

    func makeUIView(context: Context) -> SwiftUITerminalHostView {
        let view = SwiftUITerminalHostView(frame: .zero)
        view.terminalDelegate = context.coordinator
        DispatchQueue.main.async {
            context.coordinator.feedOnceIfNeeded(view, startupFeed: startupFeed)
        }
        return view
    }

    func updateUIView(_ uiView: SwiftUITerminalHostView, context: Context) {
        uiView.updateSizeIfNeeded()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        private var hasFedStartupData = false

        func feedOnceIfNeeded(_ view: TerminalView, startupFeed: ((TerminalView) -> Void)?) {
            guard let startupFeed, !hasFedStartupData else {
                return
            }
            hasFedStartupData = true
            startupFeed(view)
        }

        // MARK: - TerminalViewDelegate stubs

        public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        public func setTerminalTitle(source: TerminalView, title: String) {}
        public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        public func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        public func scrolled(source: TerminalView, position: Double) {}
        public func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {}
        public func bell(source: TerminalView) {}
        public func clipboardCopy(source: TerminalView, content: Data) {}
        public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

@available(iOS 13.0, *)
@available(visionOS 1.0, *)
private final class SwiftUITerminalHostView: TerminalView {
    private var lastAppliedSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        updateSizeIfNeeded()
    }

    func updateSizeIfNeeded() {
        let newSize = bounds.size
        guard newSize.width.isFinite, newSize.width > 0,
              newSize.height.isFinite, newSize.height > 0 else {
            return
        }
        if newSize != lastAppliedSize {
            lastAppliedSize = newSize
            processSizeChange(newSize: newSize)
        }
    }
}

@available(iOS 13.0, *)
@available(visionOS 1.0, *)
struct PreviewTerminal: View {
    var body: some View {
        SwiftUITerminalView(startupFeed: { terminal in
            terminal.feed(text: "SwiftTerm from a long family\nSwiftUI Preview\n")
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@available(iOS 13.0, *)
@available(visionOS 1.0, *)
struct PreviewTerminal_Previews: PreviewProvider {
    static var previews: some View {
        PreviewTerminal()
    }
}
#endif
