#if os(macOS)
import Testing
@testable import SwiftTerm

struct SixelBoundsTests {
    private func hook(_ handler: SixelDcsHandler) {
        var parameters = CsiParameterStorage()
        parameters.withView { handler.hook(collect: [], parameters: $0, flag: 113) }
    }

    private func decode(_ text: String, handler: SixelDcsHandler) {
        hook(handler)
        handler.put(data: Array(text.utf8)[...])
        handler.unhook()
        #expect(handler.data.isEmpty)
    }

    @Test(arguments: ["!1000000000~", "!4611686018427387904~", "!3000000~", "!2000000~-!2000000~"])
    func attackRepeatsAreRejectedBeforePixelAllocation(payload: String) {
        let host = HeadlessTerminal { _ in }
        let handler = SixelDcsHandler(terminal: host.terminal)
        decode(payload, handler: handler)
        #expect(handler.pixels.isEmpty)
        #expect(host.images.isEmpty)
    }

    @Test func inputLimitIsInclusiveAndRejectsAcrossChunksUntilHook() {
        let host = HeadlessTerminal { _ in }
        let handler = SixelDcsHandler(terminal: host.terminal,
            limits: .init(maximumInputBytes: 3, maximumPixels: 64, maximumPixelWrites: 64))
        hook(handler)
        handler.put(data: Array("!2".utf8)[...])
        handler.put(data: Array("~".utf8)[...])
        #expect(handler.data.count == 3)
        handler.unhook()
        #expect(handler.data.isEmpty)
        #expect(host.images.count == 1)
        hook(handler)
        handler.put(data: Array("!2".utf8)[...])
        handler.put(data: Array("~~".utf8)[...])
        #expect(handler.data.isEmpty)
        handler.put(data: Array("~".utf8)[...])
        handler.unhook()
        #expect(handler.data.isEmpty)
        #expect(host.images.count == 1)
        #expect(handler.pixels.isEmpty)
        decode("~", handler: handler)
        #expect(host.images.count == 2)
    }

    @Test func pixelAreaLimitIncludesExactBoundary() {
        let host = HeadlessTerminal { _ in }
        let handler = SixelDcsHandler(terminal: host.terminal,
            limits: .init(maximumInputBytes: 128, maximumPixels: 12, maximumPixelWrites: 100))
        decode("!2~", handler: handler)
        #expect(host.images.count == 1)
        #expect(handler.pixels.count == 48)
        decode("!3~", handler: handler)
        #expect(host.images.count == 1)
        #expect(handler.pixels.isEmpty)
    }

    @Test func rasterHintMustFitPixelLimitEvenWithOnePaintedPixel() {
        let host = HeadlessTerminal { _ in }
        let handler = SixelDcsHandler(terminal: host.terminal,
            limits: .init(maximumInputBytes: 128, maximumPixels: 12, maximumPixelWrites: 12))
        decode("\"1;1;3;4@", handler: handler)
        #expect(host.images.count == 1)
        decode("\"1;1;3;5@", handler: handler)
        #expect(host.images.count == 1)
        #expect(handler.pixels.isEmpty)
        decode("@", handler: handler)
        #expect(host.images.count == 2)
    }

    @Test func workCountsSetPixelsIncludingOverdraw() {
        let host = HeadlessTerminal { _ in }
        let handler = SixelDcsHandler(terminal: host.terminal,
            limits: .init(maximumInputBytes: 128, maximumPixels: 64, maximumPixelWrites: 4))
        decode("!4@", handler: handler)
        #expect(host.images.count == 1)
        decode("!4@$@", handler: handler)
        #expect(host.images.count == 1)
        #expect(handler.pixels.isEmpty)
        decode("~", handler: handler)
        #expect(host.images.count == 1)
        #expect(handler.pixels.isEmpty)
    }

    @Test func transparentPaddingDoesNotSpendPixelWork() {
        let host = HeadlessTerminal { _ in }
        let handler = SixelDcsHandler(terminal: host.terminal,
            limits: .init(maximumInputBytes: 10000, maximumPixels: 100, maximumPixelWrites: 1))
        decode(String(repeating: "!100?$", count: 1000) + "@", handler: handler)
        #expect(host.images.count == 1)
        #expect(handler.pixels.count == 400)
    }

    @Test(arguments: ["#", "\""])
    func parameterListLimitRejectsExcessAndRecovers(prefix: String) {
        let host = HeadlessTerminal { _ in }
        let handler = SixelDcsHandler(terminal: host.terminal)
        let allowed = prefix + Array(repeating: "1", count: 32).joined(separator: ";") + "~"
        decode(allowed, handler: handler)
        #expect(host.images.count == 1)
        let rejected = prefix + Array(repeating: "1", count: 33).joined(separator: ";") + "~"
        decode(rejected, handler: handler)
        #expect(host.images.count == 1)
        #expect(handler.pixels.isEmpty)
        decode("~", handler: handler)
        #expect(host.images.count == 2)
    }
}
#endif
