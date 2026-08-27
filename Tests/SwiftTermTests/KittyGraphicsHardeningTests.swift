//
//  KittyGraphicsHardeningTests.swift
//
//  Regression tests for the resource and lifetime problems that the Kitty
//  graphics rewrite introduced: a self-renewing animation timer, scrolling
//  against margins that are no longer in effect, an unbounded inflate, a
//  retained oversized APC buffer and a chunked transmission tied to one screen.
//
import Foundation
import Testing

#if canImport(Compression)
import Compression
#endif

@testable import SwiftTerm

@Suite(.serialized)
struct KittyGraphicsHardeningTests {
    private func send(
        _ terminal: Terminal,
        control: String,
        payload: [UInt8] = []
    ) {
        terminal.feed(text: "\u{1b}_G\(control);\(Data(payload).base64EncodedString())\u{1b}\\")
    }

    private func response(_ delegate: TerminalTestDelegate) -> String? {
        guard let last = delegate.sentData.last else { return nil }
        return String(decoding: last, as: UTF8.self)
    }

    // MARK: - The animation timer must not own the terminal

    @Test func loopingAnimationTimerDoesNotRetainTerminal() {
        weak var weakTerminal: Terminal?
        do {
            let (terminal, _) = TerminalTestHarness.makeTerminal()
            // A placed image with a second frame and a 60 s gap, looping for
            // ever, so that the timer is armed and stays armed for the whole
            // test. The work item re-arms itself, so a strong capture would
            // keep this terminal alive for as long as the process runs.
            send(terminal, control: "a=T,f=32,s=1,v=1,i=1,p=1,C=1", payload: [1, 2, 3, 255])
            send(terminal, control: "a=f,f=32,s=1,v=1,i=1,z=60000,X=1", payload: [4, 5, 6, 255])
            send(terminal, control: "a=a,i=1,r=1,z=60000,s=3,c=1")
            #expect(terminal.kittyAnimationTimerSerial > 0)
            weakTerminal = terminal
        }
        #expect(weakTerminal == nil)
    }

    // MARK: - Scrolling uses the margins only while margin mode is on

    /// Places a one-cell image at the top left of a DECSTBM region, scrolls the
    /// region in place and answers the absolute row the placement ends on.
    private func rowAfterInPlaceScroll(marginModeActive: Bool) -> Int? {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 80, rows: 24)
        // DECLRMM plus DECSLRM, then DECLRMM off. Turning the mode off does not
        // restore the margins, so buffer.marginLeft stays at 19.
        terminal.feed(text: "\u{1b}[?69h\u{1b}[20;60s")
        if !marginModeActive {
            terminal.feed(text: "\u{1b}[?69l")
        }
        #expect(terminal.buffer.marginLeft == 19)

        terminal.feed(text: "\u{1b}[2;10r")
        terminal.feed(text: "\u{1b}[3;1H")
        send(terminal, control: "a=T,f=32,s=1,v=1,i=1,p=1,c=1,r=1,C=1", payload: [1, 2, 3, 255])
        let placed = terminal.kittyGraphicsState.placementsByKey.values.first
        #expect(placed?.row == 2)
        #expect(placed?.col == 0)

        terminal.feed(text: "\u{1b}[10;1H\n")
        return terminal.kittyGraphicsState.placementsByKey.values.first?.row
    }

    @Test func inPlaceScrollMovesPlacementsWhenMarginModeIsOff() {
        // The text scrolls over the full width here, so the placement has to
        // travel with it even though stale margins remain set.
        #expect(rowAfterInPlaceScroll(marginModeActive: false) == 1)
    }

    @Test func inPlaceScrollKeepsPlacementsOutsideActiveMargins() {
        // With margin mode on, the columns really are restricted and a
        // placement outside them must stay where it is.
        #expect(rowAfterInPlaceScroll(marginModeActive: true) == 2)
    }

    // MARK: - The inflate is bounded by what can still be used

#if canImport(Compression)
    /// Wraps raw DEFLATE output in an RFC 1950 zlib stream, as an application
    /// sending `o=z` would.
    private func zlibStream(_ bytes: [UInt8]) -> [UInt8] {
        var deflated = [UInt8](repeating: 0, count: max(1024, bytes.count + 1024))
        let produced = bytes.withUnsafeBufferPointer { source in
            deflated.withUnsafeMutableBufferPointer { destination in
                compression_encode_buffer(
                    destination.baseAddress!, destination.count,
                    source.baseAddress!, source.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        #expect(produced > 0)
        var adlerA: UInt32 = 1
        var adlerB: UInt32 = 0
        for byte in bytes {
            adlerA = (adlerA + UInt32(byte)) % 65_521
            adlerB = (adlerB + adlerA) % 65_521
        }
        let checksum = (adlerB << 16) | adlerA
        return [0x78, 0x01] + deflated[0..<produced] + [
            UInt8((checksum >> 24) & 0xff), UInt8((checksum >> 16) & 0xff),
            UInt8((checksum >> 8) & 0xff), UInt8(checksum & 0xff)]
    }

    @Test func compressedPayloadWithinItsDeclaredSizeStillDecodes() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        send(terminal, control: "a=t,f=32,s=1,v=1,i=1,o=z",
             payload: zlibStream([1, 2, 3, 255]))
        #expect(Array(terminal.kittyGraphicsRenderSnapshot().imagesById[1]?.rgba ?? []) ==
                [1, 2, 3, 255])
    }

    @Test func compressedPayloadCannotInflateBeyondItsDeclaredSize() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        // Two megabytes of zeroes compress to a few hundred bytes. The control
        // declares a single pixel, so only four bytes could ever be used and
        // the inflate must not run past them.
        let bomb = zlibStream([UInt8](repeating: 0, count: 2 * 1024 * 1024))
        #expect(bomb.count < 4096)
        send(terminal, control: "a=t,f=32,s=1,v=1,i=1,o=z", payload: bomb)
        #expect(response(delegate) == "\u{1b}_Gi=1;EINVAL: decompression failed\u{1b}\\")
        #expect(terminal.kittyGraphicsRenderSnapshot().imagesById[1] == nil)
    }

    @Test func compressedPayloadCannotInflateBeyondStorageLimit() {
        let configuration = KittyGraphicsConfiguration(storageLimitBytesPerScreen: 1024)
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(kittyGraphics: configuration)
        // 100x100 RGBA needs 40000 bytes, far past a 1024-byte budget, so the
        // image cannot be stored whatever the payload inflates to.
        let payload = zlibStream([UInt8](repeating: 7, count: 100 * 100 * 4))
        send(terminal, control: "a=t,f=32,s=100,v=100,i=1,o=z", payload: payload)
        #expect(response(delegate) == "\u{1b}_Gi=1;EINVAL: decompression failed\u{1b}\\")
        #expect(terminal.kittyGraphicsRenderSnapshot().imagesById[1] == nil)
    }
#endif

    // MARK: - A chunked transmission belongs to the stream, not to a screen

    @Test func chunkedTransmissionSurvivesScreenSwitch() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        let image: [UInt8] = [1, 2, 3, 255]
        // A client splits the base64 stream, not the bytes behind it.
        let encoded = Array(Data(image).base64EncodedString())
        let half = encoded.count / 2
        terminal.feed(text: "\u{1b}_Ga=t,f=32,s=1,v=1,i=5,m=1;\(String(encoded[..<half]))\u{1b}\\")
        terminal.feed(text: "\u{1b}[?1049h")
        terminal.feed(text: "\u{1b}_Ga=t,m=0;\(String(encoded[half...]))\u{1b}\\")

        let onAlternate = try #require(terminal.kittyGraphicsRenderSnapshot().imagesById[5])
        #expect(Array(onAlternate.rgba) == image)

        // Nothing may be left over for the next transmission on the screen the
        // application started the chunks on.
        terminal.feed(text: "\u{1b}[?1049l")
        send(terminal, control: "a=t,f=32,s=1,v=1,i=6", payload: [9, 8, 7, 255])
        let afterReturn = try #require(terminal.kittyGraphicsRenderSnapshot().imagesById[6])
        #expect(Array(afterReturn.rgba) == [9, 8, 7, 255])
    }

    @Test func hardResetDropsAPartialTransmission() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        send(terminal, control: "a=t,f=32,s=1,v=1,i=5,m=1", payload: [1, 2])
        #expect(terminal.kittyGraphicsState.pending != nil)
        terminal.feed(text: "\u{1b}c")
        #expect(terminal.kittyGraphicsState.pending == nil)
    }

    // MARK: - Relative placements lose their parent

    @Test func relativePlacementIsRemovedWhenItsParentImagePlacementGoes() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 10)
        terminal.feed(text: "\u{1b}[3;2H")
        send(terminal, control: "a=T,f=24,s=1,v=1,i=1,p=1,c=1,r=1,C=1", payload: [1, 2, 3])
        // P names the parent image but no Q, so the child follows any client
        // placement of image 1.
        send(terminal, control: "a=T,f=24,s=1,v=1,i=2,p=1,P=1,H=1,V=1,c=1,r=1,C=1",
             payload: [4, 5, 6])
        #expect(terminal.kittyGraphicsRenderSnapshot().placements.count == 2)

        terminal.feed(text: "\u{1b}_Ga=d,d=i,i=1,p=1\u{1b}\\")
        let remaining = terminal.kittyGraphicsRenderSnapshot().placements
        #expect(remaining.isEmpty)
    }

    // MARK: - Bulk placement removal

    @Test func alternateScreenClearKeepsPrimaryPlacements() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 10)
        send(terminal, control: "a=T,f=32,s=1,v=1,i=1,p=1,c=1,r=1,C=1", payload: [1, 2, 3, 255])
        #expect(terminal.kittyGraphicsState.placementsByKey.count == 1)

        // Entering and leaving the alternate screen clears that screen only.
        // The removal runs against the alternate state while the primary one is
        // current, so it must not read whichever screen happens to be active.
        terminal.feed(text: "\u{1b}[?1049h")
        #expect(terminal.kittyGraphicsState.placementsByKey.isEmpty)
        terminal.feed(text: "\u{1b}[?1049l")
        #expect(terminal.kittyGraphicsState.placementsByKey.count == 1)
        let survivor = try #require(terminal.kittyGraphicsRenderSnapshot().placements.first)
        #expect(survivor.imageId == 1)
    }

    @Test func deletingEveryPlacementLeavesTheStoreEmpty() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 10)
        for index in 1...40 {
            terminal.feed(text: "\u{1b}[\(index % 8 + 1);\(index % 16 + 1)H")
            send(terminal, control: "a=T,f=32,s=1,v=1,i=\(index),p=1,c=1,r=1,C=1",
                 payload: [1, 2, 3, 255])
        }
        #expect(terminal.kittyGraphicsState.placementsByKey.count == 40)

        terminal.feed(text: "\u{1b}_Ga=d,d=A\u{1b}\\")
        #expect(terminal.kittyGraphicsState.placementsByKey.isEmpty)
        #expect(terminal.kittyGraphicsState.imagesById.isEmpty)
        #expect(terminal.kittyGraphicsState.totalImageBytes == 0)
    }

    // MARK: - The deprecated storage-limit option keeps working

    @available(*, deprecated)
    @Test func deprecatedCacheLimitOptionMapsToPerScreenStorageLimit() {
        var options = TerminalOptions(kittyImageCacheLimitBytes: 4096)
        #expect(options.kittyGraphics.storageLimitBytesPerScreen == 4096)
        #expect(options.kittyImageCacheLimitBytes == 4096)

        options.kittyImageCacheLimitBytes = 8192
        #expect(options.kittyGraphics.storageLimitBytesPerScreen == 8192)

        // The limit reaches the terminal, so an image over it is still refused.
        let terminal = Terminal(delegate: TerminalTestDelegate(),
                                options: TerminalOptions(kittyImageCacheLimitBytes: 3))
        terminal.feed(text: "\u{1b}_Ga=t,f=32,s=1,v=1,i=1;\(Data([1, 2, 3, 4]).base64EncodedString())\u{1b}\\")
        #expect(terminal.kittyGraphicsRenderSnapshot().imagesById.isEmpty)
    }
}
