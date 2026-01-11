//
//  Image.swift
//
//
//  Created by Miguel de Icaza on 4/29/21.
//
#if os(macOS)
import Foundation
import Testing

@testable import SwiftTerm

/// A mock TerminalImage for testing image tracking
struct MockTerminalImage: TerminalImage {
    var pixelWidth: Int = 100
    var pixelHeight: Int = 100
    var col: Int = 0
}

final class ImageTests {

    @Test func testSixel() {
        let h = HeadlessTerminal (queue: SwiftTermTests.queue) { exitCode in }
        let t = h.terminal!

        let sixel: [UInt8] = [27,  80,  113,  34,  49,  59,  49,  59,  49,  48,  48,  59,  49,  48,  48,  35,  48,  59,  49,  59,  49,  50,  48,  59,  52,  57,  59,  49,  48,  48,  35,  49,  59,  49,  59,  49,  56,  48,  59,  54,  55,  59,  57,  49,  35,  50,  59,  49,  59,  49,  56,  48,  59,  52,  57,  59,  49,  48,  48,  35,  51,  59,  49,  59,  48,  59,  52,  57,  59,  49,  48,  48,  35,  52,  59,  49,  59,  50,  52,  48,  59,  52,  57,  59,  49,  48,  48,  35,  53,  59,  49,  59,  50,  49,  50,  59,  53,  50,  59,  57,  52,  35,  54,  59,  49,  59,  57,  48,  59,  52,  55,  59,  54,  54,  35,  55,  59,  49,  59,  50,  57,  52,  59,  51,  51,  59,  49,  48,  48,  35,  56,  59,  49,  59,  51,  50,  50,  59,  54,  48,  59,  56,  53,  35,  57,  59,  49,  59,  48,  59,  57,  55,  59,  48,  35,  48,  33,  57,  48,  126,  35,  49,  33,  49,  48,  126,  45,  35,  48,  33,  57,  48,  126,  35,  49,  33,  49,  48,  126,  45,  35,  48,  33,  57,  48,  126,  35,  49,  33,  49,  48,  126,  45,  35,  48,  33,  57,  48,  66,  35,  49,  33,  49,  48,  64,  36,  35,  51,  33,  57,  48,  123,  35,  50,  33,  49,  48,  125,  45,  35,  51,  33,  57,  48,  126,  35,  50,  33,  49,  48,  126,  45,  35,  51,  33,  57,  48,  126,  35,  50,  33,  49,  48,  126,  45,  35,  51,  33,  57,  48,  78,  35,  50,  33,  49,  48,  126,  36,  35,  52,  33,  57,  48,  111,  45,  33,  57,  48,  126,  35,  50,  33,  49,  48,  126,  45,  35,  52,  33,  57,  48,  126,  35,  49,  33,  49,  48,  125,  36,  35,  50,  33,  57,  48,  63,  33,  49,  48,  64,  45,  35,  52,  33,  57,  48,  78,  35,  49,  33,  49,  48,  126,  36,  35,  53,  33,  57,  48,  111,  45,  33,  57,  48,  126,  35,  49,  33,  49,  48,  126,  45,  35,  53,  33,  57,  48,  66,  35,  49,  33,  49,  48,  126,  36,  35,  54,  33,  57,  48,  123,  45,  33,  57,  48,  126,  35,  49,  33,  49,  48,  126,  45,  35,  55,  33,  57,  48,  126,  35,  49,  33,  49,  48,  126,  45,  35,  55,  33,  57,  48,  78,  35,  49,  33,  49,  48,  126,  36,  35,  56,  33,  57,  48,  111,  45,  33,  57,  48,  126,  35,  49,  33,  49,  48,  126,  45,  35,  56,  33,  57,  48,  66,  35,  49,  33,  49,  48,  78,  36,  35,  57,  33,  57,  48,  75,  27,  92]

        t.feed(byteArray: sixel)
        #expect(h.images.count == 1)
        let image = h.images [0]
        let bytes = image.0
        let width = image.1
        let height = image.2
        #expect(bytes.count == 40000)
        #expect(width == 100)
        #expect(height == 100)
        #expect(bytes [0] == 249)
        #expect(bytes [1] == 0)
        #expect(bytes [2] == 0)
        #expect(bytes [3] == 255)
    }
}

// MARK: - Image Tracking Tests

final class ImageTrackingTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {
        // Required by TerminalDelegate
    }

    /// Test that hasAnyImages is false initially
    @Test func testHasAnyImagesInitiallyFalse() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 25))

        #expect(terminal.buffer.hasAnyImages == false, "hasAnyImages should be false initially")
        #expect(terminal.normalBuffer.hasAnyImages == false, "normalBuffer.hasAnyImages should be false initially")
        #expect(terminal.altBuffer.hasAnyImages == false, "altBuffer.hasAnyImages should be false initially")
    }

    /// Test that attaching an image sets hasAnyImages to true
    @Test func testAttachImageSetsHasAnyImages() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 25))
        let buffer = terminal.buffer

        #expect(buffer.hasAnyImages == false, "hasAnyImages should be false before attaching")

        // Attach an image to line 0
        let image = MockTerminalImage()
        buffer.attachImage(image, toLineAt: 0)

        #expect(buffer.hasAnyImages == true, "hasAnyImages should be true after attaching an image")
    }

    /// Test that attaching multiple images to the same line doesn't double-count
    @Test func testMultipleImagesOnSameLineNotDoubleCounted() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 25))
        let buffer = terminal.buffer

        // Attach first image to line 0
        buffer.attachImage(MockTerminalImage(), toLineAt: 0)
        #expect(buffer.hasAnyImages == true)

        // Attach second image to same line - should not increment count
        buffer.attachImage(MockTerminalImage(), toLineAt: 0)
        #expect(buffer.hasAnyImages == true)

        // Clear images from line 0 - should now be false (only one line had images)
        buffer.clearImagesFromLine(at: 0)
        #expect(buffer.hasAnyImages == false, "hasAnyImages should be false after clearing the only line with images")
    }

    /// Test that attaching images to multiple lines tracks correctly
    @Test func testMultipleLinesWithImages() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 25))
        let buffer = terminal.buffer

        // Attach images to multiple lines
        buffer.attachImage(MockTerminalImage(), toLineAt: 0)
        buffer.attachImage(MockTerminalImage(), toLineAt: 5)
        buffer.attachImage(MockTerminalImage(), toLineAt: 10)

        #expect(buffer.hasAnyImages == true)

        // Clear one line - should still have images
        buffer.clearImagesFromLine(at: 0)
        #expect(buffer.hasAnyImages == true, "hasAnyImages should still be true with 2 lines having images")

        // Clear another line - should still have images
        buffer.clearImagesFromLine(at: 5)
        #expect(buffer.hasAnyImages == true, "hasAnyImages should still be true with 1 line having images")

        // Clear the last line with images - should now be false
        buffer.clearImagesFromLine(at: 10)
        #expect(buffer.hasAnyImages == false, "hasAnyImages should be false after clearing all lines with images")
    }

    /// Test that clearing a line without images doesn't affect the count
    @Test func testClearLineWithoutImagesNoEffect() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 25))
        let buffer = terminal.buffer

        // Attach image to line 0
        buffer.attachImage(MockTerminalImage(), toLineAt: 0)
        #expect(buffer.hasAnyImages == true)

        // Clear a different line that has no images - should have no effect
        buffer.clearImagesFromLine(at: 5)
        #expect(buffer.hasAnyImages == true, "hasAnyImages should still be true")

        // Clear the line with images
        buffer.clearImagesFromLine(at: 0)
        #expect(buffer.hasAnyImages == false)
    }

    /// Test that buffer.clear() resets image tracking
    @Test func testBufferClearResetsImageTracking() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 25))

        // Switch to alt buffer
        terminal.feed(text: "\u{1b}[?1049h")
        let altBuffer = terminal.altBuffer

        // Attach images
        altBuffer.attachImage(MockTerminalImage(), toLineAt: 0)
        altBuffer.attachImage(MockTerminalImage(), toLineAt: 5)
        #expect(altBuffer.hasAnyImages == true)

        // Switch back to normal buffer (clears alt buffer)
        terminal.feed(text: "\u{1b}[?1049l")

        #expect(altBuffer.hasAnyImages == false, "hasAnyImages should be false after buffer.clear()")
    }

    /// Test that line recycling (scrolling) decrements the count when a line with images is recycled
    @Test func testLineRecyclingDecrementsCount() {
        // Create a terminal with small scrollback to force recycling
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 10, scrollback: 5))
        let buffer = terminal.buffer

        // Attach an image to line 0
        buffer.attachImage(MockTerminalImage(), toLineAt: 0)
        #expect(buffer.hasAnyImages == true)

        // Fill the buffer to cause scrolling and recycling
        // The buffer has 10 rows + 5 scrollback = 15 lines max
        // We need to scroll enough to recycle line 0
        for i in 0..<20 {
            terminal.feed(text: "Line \(i)\r\n")
        }

        // After enough scrolling, the line with the image should have been recycled
        #expect(buffer.hasAnyImages == false, "hasAnyImages should be false after the line with image was recycled")
    }

    /// Test that pushing a line with images (via BufferLine copy) increments count
    @Test func testPushLineWithImagesIncrementsCount() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 25))
        let buffer = terminal.buffer

        // First, attach an image to a line
        buffer.attachImage(MockTerminalImage(), toLineAt: 0)
        #expect(buffer.hasAnyImages == true)

        // Get the line with the image
        let lineWithImage = buffer.lines[0]
        #expect(lineWithImage.images != nil, "Line should have images")

        // Create a copy of the line (which copies the images)
        let copiedLine = BufferLine(from: lineWithImage)
        #expect(copiedLine.images != nil, "Copied line should have images")

        // Push the copied line - this should increment the count
        buffer.lines.push(copiedLine)

        // Now we should have 2 lines with images
        // Clear one - should still have images
        buffer.clearImagesFromLine(at: 0)
        #expect(buffer.hasAnyImages == true, "Should still have images from pushed line")
    }

    /// Test that reflow recalculates image count correctly
    @Test func testReflowRecalculatesImageCount() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 25))
        let buffer = terminal.buffer

        // Attach images to a few lines
        buffer.attachImage(MockTerminalImage(), toLineAt: 0)
        buffer.attachImage(MockTerminalImage(), toLineAt: 10)
        #expect(buffer.hasAnyImages == true)

        // Trigger a reflow by resizing
        terminal.resize(cols: 40, rows: 25)

        // After reflow, hasAnyImages should still be accurate
        // (images may have moved or been affected by reflow, but tracking should be consistent)
        let hasImages = buffer.hasAnyImages

        // Manually verify by scanning
        var foundImages = false
        for i in 0..<buffer.lines.count {
            if buffer.lines[i].images != nil {
                foundImages = true
                break
            }
        }

        #expect(hasImages == foundImages, "hasAnyImages should match actual state after reflow")
    }

    /// Test image tracking across normal and alt buffers
    @Test func testImageTrackingAcrossBuffers() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 25))

        // Attach image in normal buffer
        terminal.normalBuffer.attachImage(MockTerminalImage(), toLineAt: 0)
        #expect(terminal.normalBuffer.hasAnyImages == true)
        #expect(terminal.altBuffer.hasAnyImages == false)

        // Switch to alt buffer
        terminal.feed(text: "\u{1b}[?1049h")
        #expect(terminal.buffer === terminal.altBuffer)

        // Attach image in alt buffer
        terminal.altBuffer.attachImage(MockTerminalImage(), toLineAt: 5)
        #expect(terminal.altBuffer.hasAnyImages == true)
        #expect(terminal.normalBuffer.hasAnyImages == true, "Normal buffer should still have images")

        // Switch back to normal buffer (clears alt buffer)
        terminal.feed(text: "\u{1b}[?1049l")
        #expect(terminal.altBuffer.hasAnyImages == false, "Alt buffer should be cleared")
        #expect(terminal.normalBuffer.hasAnyImages == true, "Normal buffer should still have images")
    }
}
#endif
