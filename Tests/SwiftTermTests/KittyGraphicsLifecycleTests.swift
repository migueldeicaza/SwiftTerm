//
//  KittyGraphicsLifecycleTests.swift
//
#if os(macOS)
import Foundation
import Testing

@testable import SwiftTerm

final class KittyGraphicsLifecycleTests {
    private func makeHeadlessTerminal() -> HeadlessTerminal {
        HeadlessTerminal(queue: SwiftTermTests.queue, options: TerminalOptions(cols: 10, rows: 5)) { _ in }
    }

    private func sendKitty(terminal: Terminal, control: String, payload: [UInt8]) {
        let base64 = Data(payload).base64EncodedString()
        let sequence = "\u{1b}_G\(control);\(base64)\u{1b}\\"
        terminal.feed(text: sequence)
    }

    @Test func testKittyImagesClearedOnReset() {
        let h = makeHeadlessTerminal()
        let t = h.terminal!

        sendKitty(terminal: t,
                  control: "a=T,f=24,s=1,v=1,t=d,c=1,r=1,i=1,U=1",
                  payload: [1, 2, 3])

        #expect(t.kittyGraphicsState.imagesById[1] != nil)
        #expect(!t.kittyGraphicsState.placementsByKey.isEmpty)

        t.feed(text: "\u{1b}c")

        #expect(t.kittyGraphicsState.imagesById.isEmpty)
        #expect(t.kittyGraphicsState.imageNumbers.isEmpty)
        #expect(t.kittyGraphicsState.placementsByKey.isEmpty)
    }

    @Test func testKittyImagesClearedWhenEnteringAltBuffer() {
        let h = makeHeadlessTerminal()
        let t = h.terminal!

        t.feed(text: "\u{1b}[?1049h")
        #expect(t.isCurrentBufferAlternate)

        sendKitty(terminal: t,
                  control: "a=T,f=24,s=1,v=1,t=d,c=1,r=1,i=1,U=1",
                  payload: [1, 2, 3])

        #expect(t.kittyGraphicsState.imagesById[1] != nil)
        #expect(!t.kittyGraphicsState.placementsByKey.isEmpty)

        t.feed(text: "\u{1b}[?47l")
        #expect(!t.isCurrentBufferAlternate)

        #expect(t.kittyGraphicsState.imagesById[1] != nil)
        #expect(!t.kittyGraphicsState.placementsByKey.isEmpty)

        t.feed(text: "\u{1b}[?1049h")
        #expect(t.isCurrentBufferAlternate)

        #expect(t.kittyGraphicsState.imagesById.isEmpty)
        #expect(t.kittyGraphicsState.imageNumbers.isEmpty)
        #expect(t.kittyGraphicsState.placementsByKey.isEmpty)
    }

    // MARK: - Kitty Delete Tests (Ported from Ghostty)

    /// Test delete visible placements (d=a) - lowercase only deletes placements, not images
    /// From Ghostty: "storage: delete all placements"
    @Test func testDeleteVisiblePlacements() {
        let h = makeHeadlessTerminal()
        let t = h.terminal!

        // Create image with placement
        sendKitty(terminal: t,
                  control: "a=T,f=24,s=1,v=1,t=d,c=1,r=1,i=1,U=1",
                  payload: [1, 2, 3])

        #expect(t.kittyGraphicsState.imagesById[1] != nil)
        #expect(!t.kittyGraphicsState.placementsByKey.isEmpty)

        // Delete visible placements (lowercase 'a' - placements only, images kept)
        t.feed(text: "\u{1b}_Ga=d,d=a\u{1b}\\")

        // Placements deleted, but image still exists (lowercase doesn't cleanup images)
        #expect(t.kittyGraphicsState.imagesById[1] != nil)
        #expect(t.kittyGraphicsState.placementsByKey.isEmpty)
    }

    /// Test delete visible placements AND cleanup unreferenced images (d=A uppercase)
    /// From Ghostty: "storage: delete all placements and images"
    @Test func testDeleteVisiblePlacementsAndCleanupImages() {
        let h = makeHeadlessTerminal()
        let t = h.terminal!

        // Create image with placement
        sendKitty(terminal: t,
                  control: "a=T,f=24,s=1,v=1,t=d,c=1,r=1,i=1,U=1",
                  payload: [1, 2, 3])

        #expect(t.kittyGraphicsState.imagesById[1] != nil)
        #expect(!t.kittyGraphicsState.placementsByKey.isEmpty)

        // Delete with uppercase 'A' - deletes placements AND cleans up unreferenced images
        t.feed(text: "\u{1b}_Ga=d,d=A\u{1b}\\")

        #expect(t.kittyGraphicsState.imagesById.isEmpty)
        #expect(t.kittyGraphicsState.placementsByKey.isEmpty)
    }

    /// Test delete placements by image ID (d=i) - keeps image
    /// From Ghostty: "storage: delete all placements by image id"
    @Test func testDeletePlacementsByImageId() {
        let h = makeHeadlessTerminal()
        let t = h.terminal!

        // Create two images
        sendKitty(terminal: t,
                  control: "a=T,f=24,s=1,v=1,t=d,c=1,r=1,i=1,U=1",
                  payload: [1, 2, 3])
        sendKitty(terminal: t,
                  control: "a=T,f=24,s=1,v=1,t=d,c=1,r=1,i=2,U=1",
                  payload: [4, 5, 6])

        #expect(t.kittyGraphicsState.imagesById[1] != nil)
        #expect(t.kittyGraphicsState.imagesById[2] != nil)

        // Delete placements for image 1 (lowercase 'i' - keeps image)
        t.feed(text: "\u{1b}_Ga=d,d=i,i=1\u{1b}\\")

        // Image 1 still exists but placements for it are gone
        #expect(t.kittyGraphicsState.imagesById[1] != nil)
        #expect(t.kittyGraphicsState.imagesById[2] != nil)
    }

    /// Test delete placements by image ID AND cleanup unreferenced images (d=I uppercase)
    /// From Ghostty: "storage: delete all placements by image id and unused images"
    @Test func testDeletePlacementsByImageIdAndCleanup() {
        let h = makeHeadlessTerminal()
        let t = h.terminal!

        // Create two images
        sendKitty(terminal: t,
                  control: "a=T,f=24,s=1,v=1,t=d,c=1,r=1,i=1,U=1",
                  payload: [1, 2, 3])
        sendKitty(terminal: t,
                  control: "a=T,f=24,s=1,v=1,t=d,c=1,r=1,i=2,U=1",
                  payload: [4, 5, 6])

        #expect(t.kittyGraphicsState.imagesById[1] != nil)
        #expect(t.kittyGraphicsState.imagesById[2] != nil)

        // Delete placements for image 1 with cleanup (uppercase 'I')
        t.feed(text: "\u{1b}_Ga=d,d=I,i=1\u{1b}\\")

        // Image 1 should be cleaned up (unreferenced), image 2 still has placement
        #expect(t.kittyGraphicsState.imagesById[1] == nil)
        #expect(t.kittyGraphicsState.imagesById[2] != nil)
    }

    /// Test delete at cursor position (d=c)
    /// From Ghostty: "storage: delete intersecting cursor"
    @Test func testDeleteAtCursor() {
        let h = makeHeadlessTerminal()
        let t = h.terminal!

        // Place cursor at position and create image there
        t.feed(text: "\u{1b}[1;1H")
        sendKitty(terminal: t,
                  control: "a=T,f=24,s=1,v=1,t=d,c=1,r=1,i=1,U=1",
                  payload: [1, 2, 3])

        #expect(!t.kittyGraphicsState.placementsByKey.isEmpty)

        // Delete at cursor position
        t.feed(text: "\u{1b}_Ga=d,d=c\u{1b}\\")

        #expect(t.kittyGraphicsState.placementsByKey.isEmpty)
    }

    /// Test delete by column (d=x)
    /// From Ghostty: "storage: delete by column"
    @Test func testDeleteByColumn() {
        let h = makeHeadlessTerminal()
        let t = h.terminal!

        // Create image at column 1
        sendKitty(terminal: t,
                  control: "a=T,f=24,s=1,v=1,t=d,c=1,r=1,i=1,U=1",
                  payload: [1, 2, 3])

        #expect(!t.kittyGraphicsState.placementsByKey.isEmpty)

        // Delete by column 1
        t.feed(text: "\u{1b}_Ga=d,d=x,x=1\u{1b}\\")

        #expect(t.kittyGraphicsState.placementsByKey.isEmpty)
    }

    /// Test delete by row (d=y)
    /// From Ghostty: "storage: delete by row"
    @Test func testDeleteByRow() {
        let h = makeHeadlessTerminal()
        let t = h.terminal!

        // Create image at row 1
        sendKitty(terminal: t,
                  control: "a=T,f=24,s=1,v=1,t=d,c=1,r=1,i=1,U=1",
                  payload: [1, 2, 3])

        #expect(!t.kittyGraphicsState.placementsByKey.isEmpty)

        // Delete by row 1
        t.feed(text: "\u{1b}_Ga=d,d=y,y=1\u{1b}\\")

        #expect(t.kittyGraphicsState.placementsByKey.isEmpty)
    }

    /// Test delete at specific cell (d=p)
    /// From Ghostty: "storage: delete placement by specific id"
    @Test func testDeleteAtSpecificCell() {
        let h = makeHeadlessTerminal()
        let t = h.terminal!

        // Create image
        sendKitty(terminal: t,
                  control: "a=T,f=24,s=1,v=1,t=d,c=1,r=1,i=1,U=1",
                  payload: [1, 2, 3])

        #expect(!t.kittyGraphicsState.placementsByKey.isEmpty)

        // Delete at specific cell coordinates
        t.feed(text: "\u{1b}_Ga=d,d=p,x=1,y=1\u{1b}\\")

        #expect(t.kittyGraphicsState.placementsByKey.isEmpty)
    }

    /// Test delete by z-index (d=z)
    /// From Ghostty: delete by z-index tests
    @Test func testDeleteByZIndex() {
        let h = makeHeadlessTerminal()
        let t = h.terminal!

        // Create image with z-index
        sendKitty(terminal: t,
                  control: "a=T,f=24,s=1,v=1,t=d,c=1,r=1,i=1,U=1,z=5",
                  payload: [1, 2, 3])

        #expect(!t.kittyGraphicsState.placementsByKey.isEmpty)

        // Delete by z-index
        t.feed(text: "\u{1b}_Ga=d,d=z,z=5\u{1b}\\")

        #expect(t.kittyGraphicsState.placementsByKey.isEmpty)
    }

    /// Test delete placements by image ID range (d=r lowercase - keeps images)
    /// From Ghostty: "storage: delete images by range"
    @Test func testDeletePlacementsByIdRange() {
        let h = makeHeadlessTerminal()
        let t = h.terminal!

        // Create three images with IDs 1, 2, 3
        sendKitty(terminal: t,
                  control: "a=T,f=24,s=1,v=1,t=d,c=1,r=1,i=1,U=1",
                  payload: [1, 2, 3])
        sendKitty(terminal: t,
                  control: "a=T,f=24,s=1,v=1,t=d,c=1,r=1,i=2,U=1",
                  payload: [4, 5, 6])
        sendKitty(terminal: t,
                  control: "a=T,f=24,s=1,v=1,t=d,c=1,r=1,i=3,U=1",
                  payload: [7, 8, 9])

        #expect(t.kittyGraphicsState.imagesById[1] != nil)
        #expect(t.kittyGraphicsState.imagesById[2] != nil)
        #expect(t.kittyGraphicsState.imagesById[3] != nil)

        // Delete placements for range 1-2 (lowercase 'r' - keeps images)
        t.feed(text: "\u{1b}_Ga=d,d=r,x=1,y=2\u{1b}\\")

        // Images still exist (lowercase doesn't cleanup)
        #expect(t.kittyGraphicsState.imagesById[1] != nil)
        #expect(t.kittyGraphicsState.imagesById[2] != nil)
        #expect(t.kittyGraphicsState.imagesById[3] != nil)
    }

    /// Test delete placements by image ID range AND cleanup (d=R uppercase)
    /// From Ghostty: "storage: delete images by range"
    @Test func testDeletePlacementsByIdRangeAndCleanup() {
        let h = makeHeadlessTerminal()
        let t = h.terminal!

        // Create three images with IDs 1, 2, 3
        sendKitty(terminal: t,
                  control: "a=T,f=24,s=1,v=1,t=d,c=1,r=1,i=1,U=1",
                  payload: [1, 2, 3])
        sendKitty(terminal: t,
                  control: "a=T,f=24,s=1,v=1,t=d,c=1,r=1,i=2,U=1",
                  payload: [4, 5, 6])
        sendKitty(terminal: t,
                  control: "a=T,f=24,s=1,v=1,t=d,c=1,r=1,i=3,U=1",
                  payload: [7, 8, 9])

        #expect(t.kittyGraphicsState.imagesById[1] != nil)
        #expect(t.kittyGraphicsState.imagesById[2] != nil)
        #expect(t.kittyGraphicsState.imagesById[3] != nil)

        // Delete range 1-2 with cleanup (uppercase 'R')
        t.feed(text: "\u{1b}_Ga=d,d=R,x=1,y=2\u{1b}\\")

        // Images 1 and 2 should be cleaned up, 3 should remain
        #expect(t.kittyGraphicsState.imagesById[1] == nil)
        #expect(t.kittyGraphicsState.imagesById[2] == nil)
        #expect(t.kittyGraphicsState.imagesById[3] != nil)
    }

    /// Test chunked transmission
    /// From Ghostty: "kittygfx more chunks"
    @Test func testChunkedTransmission() {
        let h = makeHeadlessTerminal()
        let t = h.terminal!

        // Send first chunk with m=1 (more chunks coming)
        let chunk1 = Data([1, 2, 3]).base64EncodedString()
        t.feed(text: "\u{1b}_Ga=t,f=24,s=2,v=1,i=1,m=1;\(chunk1)\u{1b}\\")

        // Image should not be complete yet
        #expect(t.kittyGraphicsState.imagesById[1] == nil)

        // Send second chunk with m=0 (final chunk)
        let chunk2 = Data([4, 5, 6]).base64EncodedString()
        t.feed(text: "\u{1b}_Gm=0;\(chunk2)\u{1b}\\")

        // Now image should be complete
        #expect(t.kittyGraphicsState.imagesById[1] != nil)
    }

    /// Test quiet mode suppresses response (q=1)
    /// From Ghostty: "kittygfx more chunks with q=1"
    @Test func testQuietModeSuppressesResponse() {
        let h = makeHeadlessTerminal()
        let t = h.terminal!

        // Send with q=1 (quiet mode)
        sendKitty(terminal: t,
                  control: "a=T,f=24,s=1,v=1,t=d,c=1,r=1,i=1,U=1,q=1",
                  payload: [1, 2, 3])

        #expect(t.kittyGraphicsState.imagesById[1] != nil)
        // Response suppression is handled internally - test just verifies no crash
    }

    /// Test query command (a=q)
    /// From Ghostty: "query command"
    @Test func testQueryCommand() {
        let h = makeHeadlessTerminal()
        let t = h.terminal!

        // Create an image first
        sendKitty(terminal: t,
                  control: "a=T,f=24,s=1,v=1,t=d,c=1,r=1,i=1,U=1",
                  payload: [1, 2, 3])

        #expect(t.kittyGraphicsState.imagesById[1] != nil)

        // Send query command - should not crash
        t.feed(text: "\u{1b}_Ga=q,i=1\u{1b}\\")

        // Image should still exist
        #expect(t.kittyGraphicsState.imagesById[1] != nil)
    }
}
#endif
