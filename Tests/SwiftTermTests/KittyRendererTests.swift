#if os(macOS)
import AppKit
import Foundation
import Testing

@testable import SwiftTerm

@MainActor
@Suite(.serialized)
struct KittyRendererTests {
    private func send(
        _ view: TerminalView,
        control: String,
        payload: [UInt8] = []
    ) {
        let encoded = Data(payload).base64EncodedString()
        view.feed(text: "\u{1b}_G\(control);\(encoded)\u{1b}\\")
    }

    private func makeView() -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        view.setFrameSize(NSSize(
            width: view.cellDimension.width * 10,
            height: view.cellDimension.height * 4))
        return view
    }

    private func render(_ view: TerminalView) throws -> NSBitmapImageRep {
        view.frameTick()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func count(
        _ bitmap: NSBitmapImageRep,
        red: ClosedRange<CGFloat>,
        green: ClosedRange<CGFloat>,
        blue: ClosedRange<CGFloat>
    ) -> Int {
        var result = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                if red.contains(color.redComponent),
                   green.contains(color.greenComponent),
                   blue.contains(color.blueComponent) {
                    result += 1
                }
            }
        }
        return result
    }

    @Test func sourceClippingAndZOrderReachCpuRenderer() throws {
        let clipping = makeView()
        send(clipping,
             control: "a=T,f=32,s=2,v=1,i=1,x=1,w=1,c=1,r=1,C=1",
             payload: [255, 0, 0, 255, 0, 255, 0, 255])
        let clipped = try render(clipping)
        #expect(count(clipped, red: 0...0.2, green: 0.8...1, blue: 0...0.2) > 20)
        #expect(count(clipped, red: 0.8...1, green: 0...0.2, blue: 0...0.2) == 0)

        let layering = makeView()
        send(layering, control: "a=T,f=32,s=1,v=1,i=1,c=1,r=1,z=-1,C=1",
             payload: [255, 0, 0, 255])
        send(layering, control: "a=T,f=32,s=1,v=1,i=2,c=1,r=1,z=1,C=1",
             payload: [0, 255, 0, 255])
        let layered = try render(layering)
        #expect(count(layered, red: 0...0.2, green: 0.8...1, blue: 0...0.2) > 20)
        #expect(count(layered, red: 0.8...1, green: 0...0.2, blue: 0...0.2) == 0)
    }

    @Test func unicodePlaceholderAndAnimationUseCurrentCoreFrame() throws {
        let placeholder = makeView()
        send(placeholder, control: "a=T,f=32,s=1,v=1,i=1,c=1,r=1,U=1,C=1",
             payload: [0, 0, 255, 255])
        placeholder.feed(text: "\u{1b}[38;2;0;0;1m\u{10eeee}")
        let placeholderPixels = try render(placeholder)
        #expect(count(placeholderPixels, red: 0...0.2, green: 0...0.2, blue: 0.8...1) > 20)

        let animation = makeView()
        send(animation, control: "a=T,f=32,s=1,v=1,i=1,c=1,r=1,C=1",
             payload: [255, 0, 0, 255])
        send(animation, control: "a=f,f=32,s=1,v=1,i=1,X=1",
             payload: [0, 255, 0, 255])
        let first = try render(animation)
        #expect(count(first, red: 0.8...1, green: 0...0.2, blue: 0...0.2) > 20)

        send(animation, control: "a=a,i=1,c=2")
        let second = try render(animation)
        #expect(count(second, red: 0...0.2, green: 0.8...1, blue: 0...0.2) > 20)
    }
}
#endif
