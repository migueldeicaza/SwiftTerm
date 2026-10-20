//
//  MetalPlainTextTests.swift
//  SwiftTermTests
//
//  Rows of plain cells (one column, printable ASCII) in a font whose tables
//  prove ASCII shapes one character to one glyph skip the attributed string
//  and Core Text: the renderer maps each cell to its glyph. These tests pin
//  that the font check accepts and refuses the right fonts and tables, which
//  rows take the plain path, and that it draws exactly what the shaped path
//  draws: two renderers, one with the plain path off, render the same frames
//  of the same view and must agree on every row's vertex bytes and on the
//  pixels. Both look up glyphs in the same order, so their atlases match.
//

#if os(macOS) && canImport(MetalKit) && DEBUG
import AppKit
import CoreText
import Metal
import Testing
@testable import SwiftTerm

@MainActor
@Suite(.serialized)
struct MetalPlainTextTests {
    nonisolated static var metalIsUsable: Bool {
        MetalTerminalRenderer.shaderLibraryIsAvailable
    }

    // MARK: The font check

    @Test func systemMonospacedFacesArePlain() throws {
        let regular = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let faces = [regular,
                     NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
                     NSFontManager.shared.convert(regular, toHaveTrait: .italicFontMask)]
        for face in faces {
            let plain = try #require(PlainTextFont.analyze(face as CTFont), "\(face.fontName)")
            for code in PlainTextFont.firstCode...PlainTextFont.lastCode {
                var character = UniChar(code)
                var glyph = CGGlyph(0)
                #expect(CTFontGetGlyphsForCharacters(face as CTFont, &character, &glyph, 1))
                #expect(plain.glyph(for: code) == glyph)
            }
        }
    }

    /// A plain face shapes in the font the frame holds, so the shaped path
    /// never fits its glyphs to the cell as fallback glyphs.
    @Test func plainFacesShapeInTheFrameFont() throws {
        let regular = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        for face in [regular, NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)] {
            let plain = try #require(PlainTextFont.analyze(face as CTFont))
            #expect(CFEqual(plain.shapedFont, face as CTFont))
        }
    }

    /// Core Text shapes AAT fonts with `morx`, which the check does not read.
    @Test func aatFontsAreNotPlain() throws {
        let menlo = try #require(NSFont(name: "Menlo-Regular", size: 13))
        #expect(PlainTextFont.analyze(menlo as CTFont) == nil)
    }

    /// A GSUB table with one feature and one lookup, built by hand.
    private func gsub(feature: String, lookupType: Int, subtable: [UInt8],
                      minorVersion: UInt16 = 0, featureVariations: UInt32 = 0) -> Data {
        func u16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xff), UInt8(value & 0xff)] }
        let headerSize = minorVersion >= 1 ? 14 : 10
        // ScriptList: one script (DFLT) with a default LangSys using feature 0.
        var scriptList = u16(1) + Array("DFLT".utf8) + u16(8)
        scriptList += u16(4) + u16(0)                 // Script: default LangSys at 4, no others
        scriptList += u16(0) + u16(0xFFFF) + u16(1) + u16(0)  // LangSys
        let featureList = u16(1) + Array(feature.utf8) + u16(8) + u16(0) + u16(1) + u16(0)
        let lookupList = u16(1) + u16(4) + u16(lookupType) + u16(0) + u16(1) + u16(8) + subtable
        let scriptOffset = headerSize
        let featureOffset = scriptOffset + scriptList.count
        let lookupOffset = featureOffset + featureList.count
        var header = u16(1) + u16(Int(minorVersion)) + u16(scriptOffset) + u16(featureOffset) + u16(lookupOffset)
        if minorVersion >= 1 {
            header += [UInt8(featureVariations >> 24 & 0xff), UInt8(featureVariations >> 16 & 0xff),
                       UInt8(featureVariations >> 8 & 0xff), UInt8(featureVariations & 0xff)]
        }
        return Data(header + scriptList + featureList + lookupList)
    }

    /// Coverage format 1 for `glyphs`.
    private func coverage(_ glyphs: [Int]) -> [UInt8] {
        var bytes: [UInt8] = [0, 1, UInt8(glyphs.count >> 8), UInt8(glyphs.count & 0xff)]
        for glyph in glyphs { bytes += [UInt8(glyph >> 8), UInt8(glyph & 0xff)] }
        return bytes
    }

    /// A single substitution (format 1, delta 1) of `glyphs`.
    private func singleSubstitution(_ glyphs: [Int]) -> [UInt8] {
        [0, 1, 0, 6, 0, 1] + coverage(glyphs)
    }

    @Test func aDefaultFeatureCoveringTheGlyphsCanChangeTheRun() {
        let table = gsub(feature: "liga", lookupType: 1, subtable: singleSubstitution([5]))
        #expect(OpenTypeSubstitutionCheck.canChange(runsOf: [5, 6], gsub: table) == true)
        #expect(OpenTypeSubstitutionCheck.canChange(runsOf: [6, 7], gsub: table) == false)
    }

    @Test func anOptionalFeatureCannot() {
        for feature in ["smcp", "ss03", "cv11", "case", "zero"] {
            let table = gsub(feature: feature, lookupType: 1, subtable: singleSubstitution([5]))
            #expect(OpenTypeSubstitutionCheck.canChange(runsOf: [5], gsub: table) == false, "\(feature)")
        }
        let calt = gsub(feature: "calt", lookupType: 1, subtable: singleSubstitution([5]))
        #expect(OpenTypeSubstitutionCheck.canChange(runsOf: [5], gsub: calt) == true)
    }

    /// A chained context rule applies only when every glyph of its context
    /// can be in the run: Catalan "l·l" cannot fire in ASCII.
    @Test func aChainedContextNeedsItsWholeContext() {
        // Format 3: backtrack [5], input [9], lookahead [5], no nested lookups.
        let header: [UInt8] = [0, 3, 0, 1, 0, 20, 0, 1, 0, 26, 0, 1, 0, 32, 0, 0]
        let rule = header + [0, 0, 0, 0] + coverage([5]) + coverage([9]) + coverage([5])
        let table = gsub(feature: "locl", lookupType: 6, subtable: rule)
        #expect(OpenTypeSubstitutionCheck.canChange(runsOf: [5, 6], gsub: table) == false)
        #expect(OpenTypeSubstitutionCheck.canChange(runsOf: [5, 9], gsub: table) == true)
    }

    @Test func anExtensionLookupIsFollowed() {
        let inner = singleSubstitution([5])
        let wrapper: [UInt8] = [0, 1, 0, 1, 0, 0, 0, 8] + inner
        let table = gsub(feature: "ccmp", lookupType: 7, subtable: wrapper)
        #expect(OpenTypeSubstitutionCheck.canChange(runsOf: [5], gsub: table) == true)
        #expect(OpenTypeSubstitutionCheck.canChange(runsOf: [6], gsub: table) == false)
    }

    /// The system monospaced font with its GSUB swapped for one whose only
    /// feature, `dlig`, ligates "fi" into the "X" glyph: a pair the font
    /// check's samples never put side by side.
    private func fontWithOptionalLigature() throws -> CTFont {
        func u16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xff), UInt8(value & 0xff)] }
        func u32(_ value: Int) -> [UInt8] { u16(value >> 16 & 0xffff) + u16(value & 0xffff) }
        let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) as CTFont
        var characters = Array("fiX".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: 3)
        #expect(CTFontGetGlyphsForCharacters(mono, &characters, &glyphs, 3))
        // Ligature substitution format 1: coverage [f], one ligature set
        // holding one ligature, X from f and i.
        let ligature = u16(1) + u16(8) + u16(1) + u16(14) + coverage([Int(glyphs[0])])
            + u16(1) + u16(4) + u16(Int(glyphs[2])) + u16(2) + u16(Int(glyphs[1]))
        let gsubTag = CTFontTableTag(kCTFontTableGSUB)
        var tables = [(tag: gsubTag, bytes: [UInt8](gsub(feature: "dlig", lookupType: 4, subtable: ligature)))]
        let available = try #require(CTFontCopyAvailableTables(mono, []))
        for index in 0..<CFArrayGetCount(available) {
            let tag = CTFontTableTag(UInt(bitPattern: CFArrayGetValueAtIndex(available, index)))
            guard tag != gsubTag, let data = CTFontCopyTable(mono, tag, []) as Data? else { continue }
            tables.append((tag, [UInt8](data)))
        }
        tables.sort { $0.tag < $1.tag }
        // An sfnt: the header, a record per table, then each table padded
        // to four bytes. Core Text does not check the checksums.
        var header = u32(0x00010000) + u16(tables.count) + u16(0) + u16(0) + u16(0)
        var body: [UInt8] = []
        for table in tables {
            header += u32(Int(table.tag)) + u32(0) + u32(12 + 16 * tables.count + body.count) + u32(table.bytes.count)
            body += table.bytes + [UInt8](repeating: 0, count: (4 - table.bytes.count % 4) % 4)
        }
        let descriptor = try #require(CTFontManagerCreateFontDescriptorFromData(Data(header + body) as CFData))
        return CTFontCreateWithFontDescriptor(descriptor, 13, nil)
    }

    private func setting(_ feature: String, to value: Int, in font: CTFont) -> CTFont {
        let settings = [[kCTFontOpenTypeFeatureTag as String: feature, kCTFontOpenTypeFeatureValue as String: value]]
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontFeatureSettingsAttribute as String: settings] as CFDictionary)
        return CTFontCreateCopyWithAttributes(font, 0, nil, descriptor)
    }

    /// The table check counts optional features as off, so a font with one
    /// turned on is shaped.
    @Test func anOptionalFeatureTurnedOnIsShaped() throws {
        let font = try fontWithOptionalLigature()
        let dlig = setting("dlig", to: 1, in: font)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "fi", attributes: [.font: dlig]))
        #expect(CTLineGetGlyphCount(line) == 1)
        #expect(PlainTextFont.analyze(font) != nil)
        #expect(PlainTextFont.analyze(dlig) == nil)
    }

    @Test func unreadableOrVariableTablesCountAgainstTheFont() {
        let table = gsub(feature: "liga", lookupType: 1, subtable: singleSubstitution([5]))
        #expect(OpenTypeSubstitutionCheck.canChange(runsOf: [6], gsub: table.prefix(table.count - 6)) == nil)
        let variations = gsub(feature: "smcp", lookupType: 1, subtable: singleSubstitution([5]),
                              minorVersion: 1, featureVariations: 64)
        #expect(OpenTypeSubstitutionCheck.canChange(runsOf: [6], gsub: variations) == true)
        let unknown = gsub(feature: "liga", lookupType: 9, subtable: [0, 1, 0, 0])
        #expect(OpenTypeSubstitutionCheck.canChange(runsOf: [6], gsub: unknown) == true)
    }

    // MARK: Parity with the shaped path

    struct DrawnFrame {
        var rows: [[UInt8]]
        var pixels: [UInt8]
        var plainRows: Int
    }

    /// One view drawn by two renderers into two off-screen layers: the plain
    /// path on, and off.
    @MainActor
    final class Harness {
        let view: TerminalView
        let plain: Side
        let shaped: Side

        @MainActor
        final class Side {
            let target: TerminalMetalLayerView
            let renderer: MetalTerminalRenderer

            init?(frame: CGRect, scale: CGFloat, device: MTLDevice, plainText: Bool) {
                target = TerminalMetalLayerView(frame: frame)
                target.renderDevice = device
                target.metalLayer.framebufferOnly = false
                target.renderContentsScale = scale
                target.renderDrawableSize = CGSize(width: frame.width * scale, height: frame.height * scale)
                guard let renderer = try? MetalTerminalRenderer(target: target) else { return nil }
                renderer.waitForCompletionAfterCommit = true
                renderer.capturesRenderedTexture = true
                renderer.capturesDrawData = true
                renderer.plainTextEnabled = plainText
                self.renderer = renderer
            }
        }

        init?(font: NSFont? = nil, rows: Int = 14, scale: CGFloat = 2) {
            guard MetalPlainTextTests.metalIsUsable,
                  let device = MTLCreateSystemDefaultDevice() else { return nil }
            let frame = CGRect(x: 0, y: 0, width: 640, height: 20 * CGFloat(rows) + 20)
            view = TerminalView(frame: frame, font: font,
                                options: TerminalOptions(cols: 64, rows: rows, scrollback: 200))
            view.frameDriver.invalidate()
            view.metalScaleFactorOverride = scale
            guard let plain = Side(frame: frame, scale: scale, device: device, plainText: true),
                  let shaped = Side(frame: frame, scale: scale, device: device, plainText: false) else {
                return nil
            }
            self.plain = plain
            self.shaped = shaped
        }

        func frame(_ side: Side) async -> DrawnFrame? {
            try? await Task.sleep(for: .milliseconds(1))
            guard view.renderSnapshotForMetal(renderer: side.renderer, target: side.target),
                  let drawData = side.renderer.lastDrawData,
                  let texture = side.renderer.lastRenderedTexture else { return nil }
            let bytesPerRow = texture.width * 4
            var pixels = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
            pixels.withUnsafeMutableBytes { raw in
                texture.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow,
                                 from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                                 mipmapLevel: 0)
            }
            return DrawnFrame(rows: drawData.rows.map(Self.bytes), pixels: pixels,
                              plainRows: side.renderer.debugPlainRowCount)
        }

        private static func append(_ buffer: MTLBuffer?, count: Int, stride: Int, to out: inout [UInt8]) {
            withUnsafeBytes(of: UInt32(count)) { out.append(contentsOf: $0) }
            guard let buffer, count > 0 else { return }
            out.append(contentsOf: UnsafeRawBufferPointer(start: buffer.contents(), count: count * stride))
        }

        static func bytes(_ row: RowDrawBuffers) -> [UInt8] {
            var out: [UInt8] = []
            append(row.backgroundBuffer, count: row.backgroundCount, stride: MemoryLayout<ColorCell>.stride, to: &out)
            append(row.powerlineJoinBuffer, count: row.powerlineJoinCount, stride: MemoryLayout<ColorCell>.stride, to: &out)
            append(row.glyphGrayBuffer, count: row.glyphGrayCount, stride: MemoryLayout<TextCell>.stride, to: &out)
            append(row.glyphColorBuffer, count: row.glyphColorCount, stride: MemoryLayout<TextCell>.stride, to: &out)
            append(row.decorationBuffer, count: row.decorationCount, stride: MemoryLayout<ColorCell>.stride, to: &out)
            for images in [row.belowBackgroundImageBuffers, row.underImageBuffers, row.placeholderImageBuffers,
                           row.overImageBuffers, row.otherImageBuffers] {
                withUnsafeBytes(of: UInt32(images.count)) { out.append(contentsOf: $0) }
                for image in images {
                    append(image.buffer, count: image.vertexCount, stride: MemoryLayout<GlyphVertex>.stride, to: &out)
                }
            }
            return out
        }

        var screenRows: Int { view.withTerminal { $0.rows } }
    }

    static func sameBytes(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        a.count == b.count && a.withUnsafeBytes { a in
            b.withUnsafeBytes { b in memcmp(a.baseAddress!, b.baseAddress!, a.count) == 0 }
        }
    }

    /// Renders the current state on both sides and expects the same draw.
    /// Returns the plain side's frame.
    @discardableResult
    private func expectParity(_ harness: Harness,
                              sourceLocation: SourceLocation = #_sourceLocation) async -> DrawnFrame? {
        guard let plain = await harness.frame(harness.plain),
              let shaped = await harness.frame(harness.shaped) else {
            Issue.record("no frame", sourceLocation: sourceLocation)
            return nil
        }
        #expect(shaped.plainRows == 0, sourceLocation: sourceLocation)
        #expect(plain.rows.count == shaped.rows.count, sourceLocation: sourceLocation)
        let differing = zip(plain.rows, shaped.rows).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        #expect(differing.isEmpty, "rows whose vertex data differs: \(differing)", sourceLocation: sourceLocation)
        let samePixels = Self.sameBytes(plain.pixels, shaped.pixels)
        let differingBytes = samePixels ? 0 : zip(plain.pixels, shaped.pixels).reduce(0) { $0 + ($1.0 != $1.1 ? 1 : 0) }
        #expect(samePixels, "\(differingBytes) pixel bytes differ", sourceLocation: sourceLocation)
        return plain
    }

    /// Four ASCII cells in each combination of these colors and styles.
    static func attributeRows(cols: Int) -> [String] {
        let fgs = ["39", "31", "97", "38;5;123", "38;5;9", "38;2;205;0;0", "38;2;12;34;56"]
        let bgs = ["49", "41", "107", "48;5;17", "48;2;205;0;0", "48;2;30;30;30"]
        let styles = ["0", "1", "2", "3", "4", "4:2", "4:3", "4:4", "4:5", "5", "7", "8", "9", "1;3", "2;7",
                      "4;58;5;202", "4:3;58;2;0;255;0", "1;4;9", "5;7", "4;5;9", "5;4:3;58;5;10"]
        let samples = ["Ab1 ", "x~#.", " _|{", "Qq9@"]
        var rows: [String] = []
        var line = ""
        var cells = 0
        var n = 0
        for style in styles {
            for fg in fgs {
                for bg in bgs {
                    line += "\u{1b}[0;\(style);\(fg);\(bg)m" + samples[n % samples.count]
                    n += 1
                    cells += 4
                    if cells + 4 > cols {
                        rows.append(line + "\u{1b}[0m")
                        line = ""
                        cells = 0
                    }
                }
            }
        }
        if !line.isEmpty { rows.append(line + "\u{1b}[0m") }
        return rows
    }

    /// Every combination of colors and styles, scrolled through, selected,
    /// with blinking text hidden, links always underlined, bright colors off
    /// and a palette entry changed.
    @Test(.enabled(if: MetalPlainTextTests.metalIsUsable)) func attributesDrawAsTheShapedPathDraws() async throws {
        let harness = try #require(Harness())
        let rows = Self.attributeRows(cols: 64)
        harness.view.feed(text: rows.joined(separator: "\r\n"))
        let first = try #require(await expectParity(harness))
        #expect(first.plainRows == harness.screenRows)

        // Each screenful, from the bottom up, with blinking text shown and
        // hidden, and selected.
        while true {
            harness.view.setTextBlinkVisibleForTesting(false)
            await expectParity(harness)
            harness.view.setTextBlinkVisibleForTesting(true)
            let top = harness.view.withTerminal { $0.displayBuffer.yDisp }
            harness.view.selection.setSelection(start: Position(col: 3, row: top + 2),
                                                end: Position(col: 40, row: top + 6))
            await expectParity(harness)
            harness.view.selection.selectNone()
            guard top > 0 else { break }
            harness.view.scrollUp(lines: harness.screenRows)
            await expectParity(harness)
        }
        harness.view.useBrightColors = false
        await expectParity(harness)
        harness.view.feed(text: "\u{1b}]4;1;rgb:ff/80/00\u{1b}\\")
        await expectParity(harness)
    }

    /// Cells whose attributes differ but whose dictionaries are equal merge
    /// into one run on the shaped path, so one background quad; and erased
    /// cells that carry only a background.
    @Test(.enabled(if: MetalPlainTextTests.metalIsUsable)) func runsMergeWhereTheAttributedStringMerges() async throws {
        let harness = try #require(Harness())
        harness.view.feed(text: "\u{1b}[41;5mAB\u{1b}[25mCD\u{1b}[5mEF\u{1b}[0m\r\n"
            + "\u{1b}[31;44mred\u{1b}[38;2;205;0;0mred\u{1b}[38;5;1mred\u{1b}[0m"
            + " \u{1b}[8;42mhid\u{1b}[28mden\u{1b}[0m\r\n"
            + "\u{1b}[48;2;10;200;10m\u{1b}[K\u{1b}[0m\r\n"
            + "\u{1b}[48;5;52mabc\u{1b}[K\u{1b}[0m\r\n"
            + "\u{1b}[7m\u{1b}[K inverse to the end\u{1b}[0m")
        let frame = try #require(await expectParity(harness))
        #expect(frame.plainRows == harness.screenRows)
        // With blinking text visible, blink changes nothing in the
        // dictionary: "AB", "CD" and "EF" on red are one run, one quad.
        let backgrounds = frame.rows[0].prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(backgrounds == 1)
    }

    /// With a minimum contrast ratio, foregrounds are adjusted against their
    /// backgrounds, and the dictionary keeps the unadjusted color for shapes:
    /// cells whose adjusted colors match but whose own colors differ are
    /// separate runs.
    @Test(.enabled(if: MetalPlainTextTests.metalIsUsable)) func contrastDrawsAsTheShapedPathDraws() async throws {
        let harness = try #require(Harness())
        let rows = Self.attributeRows(cols: 64)
        harness.view.feed(text: rows.joined(separator: "\r\n") + "\r\n"
            + "\u{1b}[38;2;20;20;20;40mnear black\u{1b}[38;2;30;30;30m on black\u{1b}[38;2;250;250;250;107m white on white\u{1b}[0m")
        for ratio in [CGFloat(4.5), 7] {
            harness.view.minimumContrastRatio = ratio
            let frame = try #require(await expectParity(harness))
            #expect(frame.plainRows == harness.screenRows)
            harness.view.scrollUp(lines: harness.screenRows)
            await expectParity(harness)
            let top = harness.view.withTerminal { $0.displayBuffer.yDisp }
            harness.view.selection.setSelection(start: Position(col: 5, row: top + 1),
                                                end: Position(col: 30, row: top + 4))
            await expectParity(harness)
            harness.view.selection.selectNone()
            harness.view.scrollDown(lines: harness.screenRows)
        }
        var dense = ""
        var n = 0
        for row in 0..<20 {
            dense += "\r\n"
            for column in 0..<64 {
                let f = (n &* 37) % 256, b = (n &* 91) % 256
                dense += "\u{1b}[38;2;\(f);\(255 - f);\(column * 2);48;2;\(b);\(row % 256);\(255 - b)m"
                dense += String(UnicodeScalar(UInt8(0x21 + n % 94)))
                n += 1
            }
            dense += "\u{1b}[0m"
        }
        harness.view.feed(text: dense)
        let frame = try #require(await expectParity(harness))
        #expect(frame.plainRows == harness.screenRows)
    }

    /// Links, underlined always rather than on hover.
    @Test(.enabled(if: MetalPlainTextTests.metalIsUsable)) func linksDrawAsTheShapedPathDraws() async throws {
        let harness = try #require(Harness())
        harness.view.linkHighlightMode = .always
        harness.view.feed(text: "\u{1b}]8;;https://example.com\u{7}a link\u{1b}]8;;\u{7} and "
            + "\u{1b}]8;;https://x.y\u{7}\u{1b}[4;31manother\u{1b}]8;;\u{7}\u{1b}[0m")
        let frame = try #require(await expectParity(harness))
        #expect(frame.plainRows == harness.screenRows)
    }

    /// Dense colour, every cell its own truecolor foreground and background,
    /// as Houston's throughput test prints it.
    @Test(.enabled(if: MetalPlainTextTests.metalIsUsable)) func denseColorDrawsAsTheShapedPathDraws() async throws {
        let harness = try #require(Harness())
        var text = ""
        var n = 0
        for row in 0..<40 {
            if row > 0 { text += "\r\n" }
            for column in 0..<64 {
                let f = (n &* 37) % 256, b = (n &* 91) % 256
                text += "\u{1b}[38;2;\(f);\(255 - f);\(column * 2);48;2;\(b);\(row % 256);\(255 - b)m"
                text += String(UnicodeScalar(UInt8(0x21 + n % 94)))
                n += 1
            }
            text += "\u{1b}[0m"
        }
        harness.view.feed(text: text)
        let frame = try #require(await expectParity(harness))
        #expect(frame.plainRows == harness.screenRows)
    }

    /// Rows with anything but plain cells take the shaped path; the plain
    /// rows around them still do not.
    @Test(.enabled(if: MetalPlainTextTests.metalIsUsable)) func otherRowsKeepTheShapedPath() async throws {
        let harness = try #require(Harness())
        let shapedRows = [
            "wide 漢字", "emoji 😀", "combining e\u{301}", "accented é", "box ┌─┐",
            "powerline \u{e0b0}", "Hebrew שלום", "\u{1b}#6double width", "tab\there",
        ]
        let plainRows = ["plain one", "\u{1b}[1;32mplain two\u{1b}[0m", "plain three"]
        harness.view.feed(text: (shapedRows + plainRows).joined(separator: "\r\n"))
        let frame = try #require(await expectParity(harness))
        // A tab only moves the cursor, and the DEC line size is not a cell,
        // so both of those rows are plain too, as are the blank rows below.
        #expect(frame.plainRows == harness.screenRows - (shapedRows.count - 2))
    }

    /// A font that is not plain draws everything shaped.
    @Test(.enabled(if: MetalPlainTextTests.metalIsUsable)) func aFontThatIsNotPlainIsShaped() async throws {
        let menlo = try #require(NSFont(name: "Menlo-Regular", size: 13))
        let harness = try #require(Harness(font: menlo))
        harness.view.feed(text: "\u{1b}[31mred\u{1b}[0m and plain text")
        let frame = try #require(await expectParity(harness))
        #expect(frame.plainRows == 0)
    }

    /// A ligature turned on in the font draws as the shaped path draws it.
    @Test(.enabled(if: MetalPlainTextTests.metalIsUsable)) func anOptionalLigatureDrawsAsTheShapedPathDraws() async throws {
        let font = setting("dlig", to: 1, in: try fontWithOptionalLigature())
        let harness = try #require(Harness(font: font as NSFont))
        harness.view.feed(text: "fi and \u{1b}[31mfile\u{1b}[0m")
        let frame = try #require(await expectParity(harness))
        #expect(frame.plainRows == 0)
    }

    /// Scrolling and moving rows work the same on plain rows, at 1x too.
    @Test(.enabled(if: MetalPlainTextTests.metalIsUsable)) func plainRowsScrollAsShapedRowsDo() async throws {
        let harness = try #require(Harness(scale: 1))
        let rows = Self.attributeRows(cols: 64)
        harness.view.feed(text: rows.prefix(20).joined(separator: "\r\n"))
        await expectParity(harness)
        for line in rows.dropFirst(20).prefix(6) {
            harness.view.feed(text: "\r\n" + line)
            await expectParity(harness)
        }
    }
}
#endif
