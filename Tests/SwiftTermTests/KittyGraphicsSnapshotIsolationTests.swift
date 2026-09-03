//
//  KittyGraphicsSnapshotIsolationTests.swift
//
//  Guards the pixel handoff between the terminal and a render snapshot.
//
//  `kittyGraphicsRenderSnapshot()` used to hand out `Data(decoded.bytes)`,
//  which copied every pixel of every live image on every snapshot — that is,
//  on every frame while an image is on screen, scaling with image size. The
//  copy was removed and `KittyGraphicsRenderImage.rgba` is now the terminal's
//  own `[UInt8]`, shared by reference.
//
//  That is only safe because Swift arrays are copy-on-write and the terminal
//  never mutates a decoded payload in place while a snapshot still refers to
//  it: any in-place edit sees a refcount above one and copies first. A
//  snapshot crosses to the render thread, so if that ever stopped holding, a
//  consumer would watch its pixels change underneath it.
//
//  These tests pin both halves:
//    - the sharing actually happens (no copy), asserted on buffer identity
//      rather than on timing, so it cannot go quietly flaky;
//    - the sharing is safe, asserted by mutating the image every way the
//      protocol allows and checking an older snapshot is untouched.
//
//  No vtebench workload puts an image on screen, so nothing in the throughput
//  suites covers any of this.
//

import Foundation
import Testing

@testable import SwiftTerm

@Suite(.serialized)
struct KittyGraphicsSnapshotIsolationTests {
    private func send(
        _ terminal: Terminal,
        control: String,
        payload: [UInt8] = []
    ) {
        let encoded = Data(payload).base64EncodedString()
        terminal.feed(text: "\u{1b}_G\(control);\(encoded)\u{1b}\\")
    }

    /// A deterministic RGBA image. `seed` changes every pixel, so a stale
    /// buffer and a fresh one can never be confused for one another.
    private func syntheticRGBA(width: Int, height: Int, seed: UInt8) -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 4)
        let offset = Int(seed)
        for y in 0..<height {
            for x in 0..<width {
                bytes.append(UInt8(truncatingIfNeeded: x &+ offset))
                bytes.append(UInt8(truncatingIfNeeded: y &+ offset))
                bytes.append(UInt8(truncatingIfNeeded: x &* y &+ offset))
                bytes.append(255)
            }
        }
        return bytes
    }

    /// The address of an array's element storage. Two arrays that share
    /// copy-on-write storage report the same address; a copy reports another.
    private func storageAddress(_ bytes: [UInt8]) -> UInt {
        bytes.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
    }

    /// Transmits and displays one synthetic image, and returns its pixels.
    @discardableResult
    private func place(
        _ terminal: Terminal,
        id: UInt32,
        width: Int,
        height: Int,
        seed: UInt8
    ) -> [UInt8] {
        let pixels = syntheticRGBA(width: width, height: height, seed: seed)
        send(terminal,
             control: "a=T,f=32,s=\(width),v=\(height),i=\(id),C=1",
             payload: pixels)
        return pixels
    }

    // MARK: - The snapshot shares the terminal's pixels

    @Test func snapshotSharesPixelBufferWithTheTerminal() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        place(terminal, id: 1, width: 64, height: 64, seed: 3)

        let snapshot = terminal.kittyGraphicsRenderSnapshot()
        let image = try #require(snapshot.imagesById[1])

        // The terminal's own copy of the payload.
        let stored = try #require(terminal.kittyGraphicsState.imagesById[1])
        guard case .rgba(let storedBytes, _, _) = stored.payload else {
            Issue.record("payload is not rgba")
            return
        }

        #expect(image.rgba.count == 64 * 64 * 4)
        #expect(image.rgba == storedBytes)
        // The load-bearing assertion: same storage, so no per-snapshot copy.
        // With `Data(decoded.bytes)` these addresses differed every time.
        #expect(storageAddress(image.rgba) == storageAddress(storedBytes))
    }

    @Test func repeatedSnapshotsOfAnUnchangedImageShareOneBuffer() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        place(terminal, id: 1, width: 64, height: 64, seed: 7)

        let first = try #require(terminal.kittyGraphicsRenderSnapshot().imagesById[1])
        let second = try #require(terminal.kittyGraphicsRenderSnapshot().imagesById[1])
        let third = try #require(terminal.kittyGraphicsRenderSnapshot().imagesById[1])

        // A frame loop takes one of these per frame. None of them may copy.
        #expect(storageAddress(first.rgba) == storageAddress(second.rgba))
        #expect(storageAddress(second.rgba) == storageAddress(third.rgba))
        #expect(first.contentGeneration == third.contentGeneration)
    }

    @Test func snapshotSharesEvenALargeImage() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        // 512x512 RGBA is 1 MiB — the size at which a per-frame copy is the
        // dominant cost of taking a snapshot at all.
        place(terminal, id: 1, width: 512, height: 512, seed: 11)

        let a = try #require(terminal.kittyGraphicsRenderSnapshot().imagesById[1])
        let b = try #require(terminal.kittyGraphicsRenderSnapshot().imagesById[1])
        #expect(a.rgba.count == 512 * 512 * 4)
        #expect(storageAddress(a.rgba) == storageAddress(b.rgba))
    }

    // MARK: - Sharing is safe: an old snapshot never changes

    @Test func snapshotKeepsItsPixelsAfterTheImageIsDeleted() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        let original = place(terminal, id: 1, width: 32, height: 32, seed: 1)

        let snapshot = terminal.kittyGraphicsRenderSnapshot()
        let image = try #require(snapshot.imagesById[1])
        #expect(image.rgba == original)

        // Free the image and every placement of it.
        terminal.feed(text: "\u{1b}_Ga=d,d=I,i=1\u{1b}\\")
        #expect(terminal.kittyGraphicsRenderSnapshot().imagesById[1] == nil)

        // The snapshot taken before the delete still owns its pixels.
        #expect(image.rgba == original)
        #expect(image.rgba.count == 32 * 32 * 4)
    }

    @Test func snapshotKeepsItsPixelsAfterRetransmission() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        let original = place(terminal, id: 1, width: 16, height: 16, seed: 1)

        let before = try #require(terminal.kittyGraphicsRenderSnapshot().imagesById[1])
        #expect(before.rgba == original)

        // Same id, different pixels.
        let replacement = place(terminal, id: 1, width: 16, height: 16, seed: 200)
        let after = try #require(terminal.kittyGraphicsRenderSnapshot().imagesById[1])

        #expect(after.rgba == replacement)
        #expect(before.rgba == original, "the earlier snapshot must not follow the new pixels")
        #expect(before.contentGeneration != after.contentGeneration,
                "contentGeneration is what tells a consumer the pixels changed")
    }

    @Test func snapshotKeepsItsPixelsWhileAnAnimationAdvances() throws {
        // The animation path is the one place that edits pixels in place:
        // `composeKittyPixels(destination: &animation.frames[i].rgba, ...)`.
        // Copy-on-write is the only thing protecting an existing snapshot.
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        send(terminal, control: "a=T,f=32,s=1,v=1,i=1,C=1", payload: [1, 2, 3, 255])

        let root = try #require(terminal.kittyGraphicsRenderSnapshot().imagesById[1])
        #expect(root.rgba == [1, 2, 3, 255])

        // Add a frame, then make it the displayed one.
        send(terminal, control: "a=f,f=32,s=1,v=1,i=1,z=10,X=1", payload: [40, 50, 60, 255])
        send(terminal, control: "a=a,i=1,c=2", payload: [])

        let advanced = try #require(terminal.kittyGraphicsRenderSnapshot().imagesById[1])
        #expect(advanced.rgba == [40, 50, 60, 255])
        #expect(root.rgba == [1, 2, 3, 255], "the pre-animation snapshot must be untouched")

        // Compose over the frame that is currently displayed.
        send(terminal, control: "a=f,f=32,s=1,v=1,i=1,r=2,X=1", payload: [7, 8, 9, 255])
        let composed = try #require(terminal.kittyGraphicsRenderSnapshot().imagesById[1])

        #expect(root.rgba == [1, 2, 3, 255])
        #expect(advanced.rgba == [40, 50, 60, 255],
                "an in-place frame edit must copy rather than reach into a live snapshot")
        #expect(composed.rgba == [7, 8, 9, 255])
    }

    @Test func snapshotKeepsItsPixelsAcrossAScreenSwitch() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        let original = place(terminal, id: 1, width: 8, height: 8, seed: 5)
        let image = try #require(terminal.kittyGraphicsRenderSnapshot().imagesById[1])

        // The alternate screen keeps its own placement store; coming back must
        // not disturb pixels a snapshot already handed to a renderer.
        terminal.feed(text: "\u{1b}[?1049h")
        _ = terminal.kittyGraphicsRenderSnapshot()
        terminal.feed(text: "\u{1b}[?1049l")

        #expect(image.rgba == original)
        #expect(terminal.kittyGraphicsRenderSnapshot().imagesById[1]?.rgba == original)
    }

    // MARK: - The placement geometry a renderer draws from

    @Test func placedImageReachesTheSnapshotWithGeometry() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        place(terminal, id: 1, width: 32, height: 32, seed: 9)

        let snapshot = terminal.kittyGraphicsRenderSnapshot()
        #expect(snapshot.placements.count == 1)
        let placement = try #require(snapshot.placements.first)
        #expect(placement.imageId == 1)
        #expect(placement.visibleSource.width == 32)
        #expect(placement.visibleSource.height == 32)
        #expect(placement.geometry.columns >= 1)
        #expect(placement.geometry.rows >= 1)
    }
}
