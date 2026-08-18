#if os(macOS)
import AppKit
import Metal
import Testing

@testable import SwiftTerm

@MainActor
@Suite(.serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct MetalRendererStatusTests {
    private func makeView() -> TerminalView {
        TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
    }

    private func recoveryReport() -> MetalRendererRecoveryReport {
        MetalRendererRecoveryReport(
            reason: .activeFrame,
            failureDuration: 1,
            commandBufferStatus: .scheduled,
            commandBufferError: nil
        )
    }

    @Test func explicitMetalSessionAndPresentationUpdatePublicStatus() throws {
        let view = makeView()
        var notifications: [MetalRendererStatus] = []
        var notificationsWereOnMainThread = true
        let observer = NotificationCenter.default.addObserver(
            forName: .terminalViewMetalRendererStatusDidChange,
            object: view,
            queue: nil
        ) { notification in
            notificationsWereOnMainThread = notificationsWereOnMainThread && Thread.isMainThread
            if let terminalView = notification.object as? TerminalView {
                notifications.append(terminalView.metalRendererStatus)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try view.setUseMetal(true)
        #expect(view.metalRendererStatus.state == .waitingForFirstFrame)
        #expect(view.metalRendererStatus.presentedFrameCount == 0)
        #expect(view.metalRendererStatus.lastFramePresentedAt == nil)

        let renderer = try #require(view.metalRenderer)
        let presentedAt = Date(timeIntervalSince1970: 123)
        view.metalRenderer(renderer, didPresentAt: presentedAt)
        #expect(view.metalRendererStatus == MetalRendererStatus(
            state: .healthy,
            presentedFrameCount: 1,
            lastFramePresentedAt: presentedAt
        ))

        try view.setUseMetal(false)
        #expect(view.metalRendererStatus.state == .disabled)
        #expect(view.metalRendererStatus.presentedFrameCount == 1)

        try view.setUseMetal(true)
        #expect(view.metalRendererStatus == MetalRendererStatus(
            state: .waitingForFirstFrame,
            presentedFrameCount: 0,
            lastFramePresentedAt: nil
        ))
        #expect(notifications.count == 4)
        #expect(notificationsWereOnMainThread)
    }

    @Test func commandWorkWithoutPresentationDoesNotMarkRendererHealthy() throws {
        let view = makeView()
        try view.setUseMetal(true)

        view.drawMetalFrameNow()

        #expect(view.metalRendererStatus.state == .waitingForFirstFrame)
        #expect(view.metalRendererStatus.presentedFrameCount == 0)
    }

    @Test func automaticReplacementPreservesPresentationCountUntilNewPresentation() throws {
        let view = makeView()
        try view.setUseMetal(true)
        let oldRenderer = try #require(view.metalRenderer)
        view.metalRenderer(oldRenderer, didPresentAt: Date(timeIntervalSince1970: 100))

        view.metalRenderer(oldRenderer, requiresRecovery: recoveryReport())

        let replacement = try #require(view.metalRenderer)
        #expect(replacement !== oldRenderer)
        #expect(view.metalRendererStatus.state == .recovering)
        #expect(view.metalRendererStatus.presentedFrameCount == 1)

        view.metalRenderer(oldRenderer, didPresentAt: Date(timeIntervalSince1970: 101))
        #expect(view.metalRendererStatus.presentedFrameCount == 1)

        view.metalRenderer(replacement, didPresentAt: Date(timeIntervalSince1970: 102))
        #expect(view.metalRendererStatus.state == .healthy)
        #expect(view.metalRendererStatus.presentedFrameCount == 2)
    }

    @Test func repeatedStallFallsBackToCoreGraphics() throws {
        let view = makeView()
        try view.setUseMetal(true)
        let first = try #require(view.metalRenderer)
        view.metalRenderer(first, requiresRecovery: recoveryReport())
        let replacement = try #require(view.metalRenderer)

        view.metalRenderer(replacement, requiresRecovery: recoveryReport())

        #expect(!view.isUsingMetalRenderer)
        #expect(view.metalRenderer == nil)
        #expect(view.metalRendererStatus.state == .fellBackToCoreGraphics)
    }

#if DEBUG
    @Test func replacementInitializationFailureFallsBackToCoreGraphics() throws {
        let view = makeView()
        try view.setUseMetal(true)
        let renderer = try #require(view.metalRenderer)
        view.failNextMetalRendererReplacementForTesting = true

        view.metalRenderer(renderer, requiresRecovery: recoveryReport())

        #expect(!view.isUsingMetalRenderer)
        #expect(view.metalRendererStatus.state == .fellBackToCoreGraphics)
    }
#endif
}
#endif
