//
//  GlyphAtlasTests.swift
//
//  Tests for the Metal glyph atlas packing, grow, reset and frozen behavior.
//
//  Created for issue #596: CJK-heavy output exhausted the atlas and stale
//  regions produced inverted-color block runs.
//

#if os(macOS)
import Foundation
import Metal
import Testing

@testable import SwiftTerm

@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct GlyphAtlasTests {
    let device = MTLCreateSystemDefaultDevice()!

    private func makeAtlas(size: Int, maxSize: Int, format: GlyphAtlasFormat = .bgra) -> GlyphAtlas {
        let atlas = GlyphAtlas(device: device, size: size, maxSize: maxSize, format: format)
        precondition(atlas != nil, "atlas creation should not fail")
        return atlas!
    }

    /// A bitmap in the layout `GlyphAtlas.write` expects: bottom-up rows of
    /// BGRA pixels, with a deterministic per-byte pattern derived from `seed`.
    private func makePixels(width: Int, height: Int, seed: Int) -> [UInt8] {
        (0..<(width * height * 4)).map { UInt8(($0 &+ seed) % 251) }
    }

    /// Reads the atlas texture back and checks that `region` holds `pixels`
    /// (accounting for the vertical flip that `write` performs).
    private func regionMatches(atlas: GlyphAtlas, region: AtlasRegion, pixels: [UInt8]) -> Bool {
        let width = region.width
        let height = region.height
        var readback = [UInt8](repeating: 0, count: width * height * 4)
        readback.withUnsafeMutableBytes { raw in
            atlas.texture.getBytes(raw.baseAddress!,
                                   bytesPerRow: width * 4,
                                   from: MTLRegionMake2D(region.x, region.y, width, height),
                                   mipmapLevel: 0)
        }
        let stride = width * 4
        for row in 0..<height {
            let srcRow = height - 1 - row
            if readback[(row * stride)..<((row + 1) * stride)] != pixels[(srcRow * stride)..<((srcRow + 1) * stride)] {
                return false
            }
        }
        return true
    }

    @Test func shelfPackingProducesDisjointRegions() throws {
        let atlas = makeAtlas(size: 256, maxSize: 256)
        var regions: [AtlasRegion] = []
        let sizes = [(30, 40), (50, 20), (64, 64), (10, 70), (80, 30), (25, 25)]
        for (width, height) in sizes {
            let region = try #require(atlas.ensureRegion(width: width, height: height))
            #expect(!atlas.didReset)
            #expect(region.width == width && region.height == height)
            regions.append(region)
        }
        for i in 0..<regions.count {
            for j in (i + 1)..<regions.count {
                let a = regions[i]
                let b = regions[j]
                let overlaps = a.x < b.x + b.width && b.x < a.x + a.width &&
                               a.y < b.y + b.height && b.y < a.y + a.height
                #expect(!overlaps, "regions \(i) and \(j) overlap")
            }
        }
    }

    /// Growth must preserve the pixel coordinates of previously written
    /// regions: the renderer keeps its glyph cache across grows.
    @Test func growPreservesRegionPixels() throws {
        let atlas = makeAtlas(size: 256, maxSize: 512)
        let width = 16
        let height = 16
        let pixels = makePixels(width: width, height: height, seed: 7)
        let region = try #require(atlas.ensureRegion(width: width, height: height))
        atlas.write(region: region, pixels: pixels, width: width, height: height)

        // Fill until the atlas is forced to grow.
        var grew = false
        for _ in 0..<40 {
            let previousSize = atlas.size
            let filler = try #require(atlas.ensureRegion(width: 60, height: 60))
            #expect(!atlas.didReset, "atlas should grow, not reset")
            atlas.write(region: filler,
                        pixels: makePixels(width: 60, height: 60, seed: 3),
                        width: 60,
                        height: 60)
            if atlas.size != previousSize {
                grew = true
                break
            }
        }
        #expect(grew, "atlas never grew; test setup is wrong")
        #expect(atlas.size == 512)
        #expect(regionMatches(atlas: atlas, region: region, pixels: pixels),
                "pixels moved or were corrupted by grow")
    }

    @Test func resetAtMaxSizeSetsDidReset() throws {
        let atlas = makeAtlas(size: 256, maxSize: 256)
        for _ in 0..<4 {
            _ = try #require(atlas.ensureRegion(width: 120, height: 120))
            #expect(!atlas.didReset)
        }
        // The atlas is now full and cannot grow: the next request recycles it.
        let region = try #require(atlas.ensureRegion(width: 120, height: 120))
        #expect(atlas.didReset)
        #expect(atlas.size == 256)
        // Packing restarted from the origin (1px glyph padding).
        #expect(region.x <= 2 && region.y <= 2)
    }

    @Test func frozenAtlasReturnsNilInsteadOfResetting() throws {
        let atlas = makeAtlas(size: 256, maxSize: 256)
        for _ in 0..<4 {
            _ = try #require(atlas.ensureRegion(width: 120, height: 120))
        }
        atlas.frozen = true
        let region = atlas.ensureRegion(width: 120, height: 120)
        #expect(region == nil)
        #expect(!atlas.didReset)
        #expect(atlas.size == 256)
        // Unfreezing restores the normal recycle behavior.
        atlas.frozen = false
        let recycled = atlas.ensureRegion(width: 120, height: 120)
        #expect(recycled != nil)
        #expect(atlas.didReset)
    }

    /// Regression test: when the atlas grows to maxSize but the pending
    /// request still does not fit below the current shelf, ensureRegion must
    /// fall through to a reset instead of returning nil with a grown atlas.
    @Test func growWithUnfittableReserveFallsBackToReset() throws {
        let atlas = makeAtlas(size: 256, maxSize: 512)
        for _ in 0..<4 {
            _ = try #require(atlas.ensureRegion(width: 120, height: 120))
        }
        // 450 tall does not fit at 256; after growing to 512 it still does
        // not fit below the current shelf (y=122, 122+452 > 512), so the
        // atlas must reset.
        let region = try #require(atlas.ensureRegion(width: 20, height: 450))
        #expect(atlas.didReset)
        #expect(atlas.size == 512)
        #expect(region.x <= 2 && region.y <= 2)
    }

    @Test func oversizedRequestReturnsNilWithoutStateChange() {
        let atlas = makeAtlas(size: 256, maxSize: 512)
        let region = atlas.ensureRegion(width: 600, height: 10)
        #expect(region == nil)
        #expect(!atlas.didReset)
        #expect(atlas.size == 256)
        // The atlas is still usable afterwards.
        #expect(atlas.ensureRegion(width: 8, height: 8) != nil)
    }

    @Test func recommendedMaxSizeWithinDeviceLimits() {
        let deviceMax = GlyphAtlas.maxTextureDimension(of: device)
        #expect(deviceMax >= 8192)
        for format in [GlyphAtlasFormat.grayscale, .bgra] {
            let recommended = GlyphAtlas.recommendedMaxSize(device: device, format: format)
            #expect(recommended >= 256)
            #expect(recommended <= deviceMax)
        }
    }
}
#endif
