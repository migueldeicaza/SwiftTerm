import Foundation
import Testing

@testable import SwiftTerm

struct CellStorageTests {
    @Test func packedCellHasEightByteLayout() {
        #expect(MemoryLayout<PackedCell>.size == 8)
        #expect(MemoryLayout<PackedCell>.stride == 8)
        #expect(MemoryLayout<PackedCell>.alignment == 8)
    }

    @Test func packedAsciiRunReadsFromANonzeroSliceIndex() {
        let line = BufferLine(cols: 6)
        let backing = Array("xABCDEy".utf8)
        let source = backing[1..<6]

        line.setPackedAsciiRun(source, sourceStart: 2, count: 3, at: 1,
                               styleID: 0, semanticContentCode: 5)

        #expect(line.packedCell(at: 0).content == 0)
        #expect((1...3).map { line.packedCell(at: $0).content }
                == Array("BCD".utf8).map(UInt32.init))
        #expect((1...3).allSatisfy {
            line.packedCell(at: $0).semanticContentCode == 5
        })
        #expect(line.packedCell(at: 4).content == 0)
    }

    @Test func packedScalarRunsWriteNarrowAndWideCells() {
        let narrowLine = BufferLine(cols: 4)
        let narrowScalars: [UInt32] = [0x03B1, 0x0416, 0x0645]
        narrowScalars.withUnsafeBufferPointer { scalars in
            narrowLine.setPackedScalarRun(
                scalars, sourceStart: 0, count: scalars.count, at: 1,
                widthState: .narrow, styleID: 0, payloadCode: 17,
                semanticContentCode: 5)
        }

        #expect((1...3).map { narrowLine.packedCell(at: $0).content } == narrowScalars)
        #expect((1...3).allSatisfy {
            let cell = narrowLine.packedCell(at: $0)
            return cell.widthState == .narrow &&
                cell.payloadCode == 17 && cell.semanticContentCode == 5
        })

        let wideLine = BufferLine(cols: 4)
        let wideScalars: [UInt32] = [0x4E2D, 0x754C]
        wideScalars.withUnsafeBufferPointer { scalars in
            wideLine.setPackedScalarRun(
                scalars, sourceStart: 0, count: scalars.count, at: 0,
                widthState: .wide, styleID: 0, semanticContentCode: 6)
        }

        #expect(wideLine.packedCell(at: 0).content == wideScalars[0])
        #expect(wideLine.packedCell(at: 0).widthState == .wide)
        #expect(wideLine.packedCell(at: 1).widthState == .spacerTail)
        #expect(wideLine.packedCell(at: 2).content == wideScalars[1])
        #expect(wideLine.packedCell(at: 2).widthState == .wide)
        #expect(wideLine.packedCell(at: 3).widthState == .spacerTail)
        #expect((0..<4).allSatisfy {
            wideLine.packedCell(at: $0).semanticContentCode == 6
        })
    }

    @Test func zeroIsTheEmptyCell() {
        let cell = PackedCell()

        #expect(cell.rawValue == 0)
        #expect(cell.contentTag == .codepoint)
        #expect(cell.content == 0)
        #expect(cell.styleID == 0)
        #expect(cell.widthState == .narrow)
        #expect(!cell.isProtected)
        #expect(!cell.hasPayload)
        #expect(cell.semanticContentCode == 0)
        #expect(cell.hasValidEncoding)
    }

    @Test func unicodeScalarBoundariesValidate() {
        for value: UInt32 in [0, 0xd7ff, 0xe000, 0x10ffff] {
            let cell = PackedCell.make(contentTag: .codepoint, content: value,
                                       styleID: 0, widthState: .narrow,
                                       isProtected: false, hasPayload: false,
                                       semanticContentCode: 0)
            #expect(cell?.content == value)
        }

        let surrogate = UInt64(0xd800) << PackedCell.contentShift
        let tooLarge = UInt64(0x110000) << PackedCell.contentShift
        #expect(PackedCell(validatingRawValue: surrogate) == nil)
        #expect(PackedCell(validatingRawValue: tooLarge) == nil)
    }

    @Test func payloadBitsRoundTripAndInvalidValuesFailValidation() {
        let payloadCell = PackedCell.make(contentTag: .codepoint, content: 65,
                                          styleID: 0, widthState: .narrow,
                                          isProtected: false, payloadCode: 0xbeef,
                                          semanticContentCode: 0)
        #expect(payloadCell?.payloadCode == 0xbeef)
        #expect(PackedCell(validatingRawValue: UInt64(7) << PackedCell.semanticContentShift) == nil)

        let paletteTag = UInt64(PackedCell.ContentTag.backgroundPalette.rawValue)
        let oversizedPalette = paletteTag | (UInt64(256) << PackedCell.contentShift)
        #expect(PackedCell(validatingRawValue: oversizedPalette) == nil)
    }

    @Test func backgroundOnlyCellsRoundTrip() {
        let paletteAttribute = Attribute(fg: .defaultColor, bg: .ansi256(code: 42), style: .none)
        let rgbAttribute = Attribute(fg: .defaultColor,
                                     bg: .trueColor(red: 12, green: 34, blue: 56),
                                     style: .none)
        let page = CellStoragePage(count: 2)

        page.setCell(CharData(attribute: paletteAttribute), at: 0)
        page.setCell(CharData(attribute: rgbAttribute), at: 1)

        #expect(page.rawCell(at: 0).contentTag == .backgroundPalette)
        #expect(page.rawCell(at: 0).content == 42)
        #expect(page.rawCell(at: 0).styleID == 0)
        #expect(page.cell(at: 0).attribute == paletteAttribute)

        #expect(page.rawCell(at: 1).contentTag == .backgroundRGB)
        #expect(page.rawCell(at: 1).content == 0x38220c)
        #expect(page.rawCell(at: 1).styleID == 0)
        #expect(page.cell(at: 1).attribute == rgbAttribute)
    }

    @Test func flagsAndSemanticValuesRoundTrip() throws {
        let atom = try #require(TinyAtom.lookup(value: "payload"))
        defer { atom.release() }
        let semanticValues: [SemanticContent] = [
            .none,
            .prompt(.initial),
            .prompt(.right),
            .prompt(.continuation),
            .prompt(.secondary),
            .input,
            .output
        ]

        for (code, semanticContent) in semanticValues.enumerated() {
            var value = CharData(attribute: CharData.defaultAttr, code: 65, size: 2)
            value.setProtected(true)
            value.setPayload(atom: atom)
            value.setSemanticContent(semanticContent)
            let page = CellStoragePage(count: 1)
            page.setCell(value, at: 0)

            let packed = page.rawCell(at: 0)
            #expect(packed.widthState == .wide)
            #expect(packed.isProtected)
            #expect(packed.hasPayload)
            #expect(packed.semanticContentCode == UInt8(code))
            #expect(page.cell(at: 0).semanticContent == semanticContent)
            #expect(page.cell(at: 0).getPayload() as? String == "payload")
        }

        for state in [PackedCell.WidthState.narrow, .wide, .spacerTail, .spacerHead] {
            let cell = PackedCell.make(contentTag: .codepoint, content: 65,
                                       styleID: 0, widthState: state,
                                       isProtected: false, hasPayload: false,
                                       semanticContentCode: 0)
            #expect(cell?.widthState == state)
        }
    }

    @Test func equalAttributesShareAReferenceCountedStyle() {
        let attribute = Attribute(fg: .ansi256(code: 3), bg: .defaultColor,
                                  style: [.bold, .italic])
        let page = CellStoragePage(count: 2)
        page.setCell(CharData(attribute: attribute, code: 65), at: 0)
        page.setCell(CharData(attribute: attribute, code: 66), at: 1)

        let identifier = page.rawCell(at: 0).styleID
        #expect(identifier != 0)
        #expect(page.rawCell(at: 1).styleID == identifier)
        #expect(page.styleCount == 1)
        #expect(page.styleReferenceCount(for: identifier) == 2)

        page.setCell(CharData.Null, at: 0)
        #expect(page.styleReferenceCount(for: identifier) == 1)
        page.setCell(CharData.Null, at: 1)
        #expect(page.styleCount == 0)
    }

    @Test func internedAttributeKeyPreservesEveryAttributeField() throws {
        let base = CharData.defaultAttr
        let colors: [Attribute.Color] = [
            .defaultColor,
            .defaultInvertedColor,
            .ansi256(code: 0),
            .ansi256(code: 255),
            .trueColor(red: 0, green: 0, blue: 0),
            .trueColor(red: 255, green: 255, blue: 255),
            .trueColor(red: 17, green: 34, blue: 51),
        ]
        let styles: [CharacterStyle] = [
            .none, .bold, .underline, .blink, .inverse,
            .invisible, .dim, .italic, .crossedOut,
            [.bold, .underline, .italic, .crossedOut],
        ]
        let underlineStyles: [UnderlineStyle] = [
            .none, .single, .double, .curly, .dotted, .dashed,
        ]

        var attributes = [base]
        attributes += colors.map {
            Attribute(fg: $0, bg: base.bg, style: base.style)
        }
        attributes += colors.map {
            Attribute(fg: base.fg, bg: $0, style: base.style)
        }
        attributes += styles.map {
            Attribute(fg: base.fg, bg: base.bg, style: $0)
        }
        attributes += underlineStyles.map {
            Attribute(fg: base.fg, bg: base.bg, style: base.style,
                      underlineStyle: $0)
        }
        attributes += colors.map {
            Attribute(fg: base.fg, bg: base.bg, style: base.style,
                      underlineColor: $0)
        }

        let distinctAttributes = Array(Set(attributes))
        let keys = distinctAttributes.map(InternedAttributeKey.init)
        #expect(Set(keys).count == distinctAttributes.count)
        #expect(InternedAttributeKey(base) == InternedAttributeKey(base))

        let arena = CellArena(styleCapacity: distinctAttributes.count)
        var identifiers: [UInt16] = []
        for attribute in distinctAttributes {
            identifiers.append(try #require(arena.intern(attribute: attribute)))
        }
        #expect(Set(identifiers).count == distinctAttributes.count)
        for (attribute, identifier) in zip(distinctAttributes, identifiers) {
            #expect(arena.intern(attribute: attribute) == identifier)
        }
    }

    @Test func arenaOwnedStylePackingDoesNotReinternAttributes() throws {
        let arena = CellArena()
        let attribute = Attribute(fg: .ansi256(code: 3), bg: .ansi256(code: 4),
                                  style: [.bold, .italic])
        let styleID = try #require(arena.intern(attribute: attribute))
        let attributeCount = arena.attributeCount

        for scalar in UInt32(32)..<UInt32(127) {
            let cell = try #require(arena.pack(styleID: styleID, scalar: scalar,
                                               widthState: .narrow))
            #expect(cell.styleID == styleID)
            #expect(arena.attribute(for: cell) == attribute)
        }

        #expect(arena.attributeCount == attributeCount)
    }

    @Test func packedAttributeKeysIgnoreCharacterContent() throws {
        let arena = CellArena()
        let attribute = Attribute(fg: .ansi256(code: 2), bg: .defaultColor,
                                  style: .bold)
        let styleID = try #require(arena.intern(attribute: attribute))
        let ascii = try #require(arena.pack(styleID: styleID, scalar: 65,
                                            widthState: .narrow))
        let grapheme = try #require(arena.pack(styleID: styleID,
                                               character: Character("e\u{301}"),
                                               widthState: .narrow))
        let background = try #require(arena.pack(
            attribute: Attribute(fg: .defaultColor, bg: .ansi256(code: 2), style: .none),
            scalar: 0, widthState: .narrow))

        #expect(ascii.attributeKey == grapheme.attributeKey)
        #expect(ascii.attributeKey != background.attributeKey)
    }

    @Test func graphemeAndPayloadSurviveAllLineCopies() throws {
        let grapheme = Character("e\u{301}")
        let atom = try #require(TinyAtom.lookup(value: "https://example.com"))
        defer { atom.release() }

        var value = CharData(attribute: CharData.defaultAttr, code: 0)
        value.setCharacter(grapheme, size: 1)
        value.setPayload(atom: atom)

        let line = BufferLine(cols: 4)
        line[0] = value
        line.insertCells(pos: 0, n: 1, rightMargin: 3, fillData: CharData.Null)
        #expect(line[1].getCharacter() == grapheme)
        #expect(line[1].getPayload() as? String == "https://example.com")

        line.deleteCells(pos: 0, n: 1, rightMargin: 3, fillData: CharData.Null)
        line.resize(cols: 6, fillData: CharData.Null)
        #expect(line[0].getCharacter() == grapheme)

        let clone = BufferLine(from: line)
        let destination = BufferLine(cols: 6)
        destination.copyFrom(clone, srcCol: 0, dstCol: 3, len: 1)
        #expect(destination[3].getCharacter() == grapheme)
        #expect(destination[3].getPayload() as? String == "https://example.com")

        destination.fill(with: CharData.Null)
        #expect(!destination[3].hasPayload)
        #expect(destination[3].isSimpleRune)
    }

    @Test func terminalArenaMakesLineAndSnapshotCopiesRaw() throws {
        let arena = CellArena()
        let attribute = Attribute(fg: .ansi256(code: 5), bg: .defaultColor,
                                  style: [.bold, .italic])
        let source = BufferLine(cols: 4, arena: arena)
        var value = CharData(attribute: attribute, code: 0)
        value.setCharacter(Character("e\u{301}"), size: 1)
        source[0] = value

        let styleCount = arena.attributeCount
        let graphemeCount = arena.graphemeCount
        let clone = BufferLine(from: source)
        #if os(macOS) || os(iOS) || os(visionOS) || os(macCatalyst)
        let snapshotRow = TerminalSnapshot.Row(source: source)
        snapshotRow.line.copyForSnapshot(from: source,
                                         arena: snapshotRow.line.cellArena)
        #endif

        #expect(clone.cellArena === arena)
        #if os(macOS) || os(iOS) || os(visionOS) || os(macCatalyst)
        #expect(snapshotRow.line.cellArena !== arena)
        #endif
        #expect(clone.packedCell(at: 0) == source.packedCell(at: 0))
        #if os(macOS) || os(iOS) || os(visionOS) || os(macCatalyst)
        #expect(snapshotRow.line.packedCell(at: 0) == source.packedCell(at: 0))
        #expect(snapshotRow.line.packedCharacter(at: 0) == Character("e\u{301}"))
        #endif
        #expect(arena.attributeCount == styleCount)
        #expect(arena.graphemeCount == graphemeCount)

        #if os(macOS) || os(iOS) || os(visionOS) || os(macCatalyst)
        let snapshotArena = snapshotRow.line.cellArena
        let laterAttribute = Attribute(fg: .ansi256(code: 7), bg: .defaultColor,
                                       style: .underline)
        let laterStyleID = try #require(arena.intern(attribute: laterAttribute))
        let laterGraphemeID = try #require(arena.intern(grapheme: [0x78, 0x0301]))

        #expect(snapshotArena.attributeCount == styleCount)
        #expect(snapshotArena.graphemeCount == graphemeCount)
        #expect(arena.attributeCount == styleCount + 1)
        #expect(arena.graphemeCount == graphemeCount + 1)
        #expect(snapshotRow.line.packedCharacter(at: 0) == Character("e\u{301}"))

#if DEBUG
        let copiedAttributes = snapshotArena.snapshotAttributeEntriesCopied
        let copiedGraphemes = snapshotArena.snapshotGraphemeEntriesCopied
#endif
        #expect(snapshotArena.synchronizeSnapshotPrefix(from: arena))
        #expect(snapshotArena.attributeCount == styleCount + 1)
        #expect(snapshotArena.graphemeCount == graphemeCount + 1)
        #expect(snapshotArena.attribute(for: laterStyleID) == laterAttribute)
        #expect(snapshotArena.grapheme(for: laterGraphemeID) == [0x78, 0x0301])
#if DEBUG
        #expect(snapshotArena.snapshotAttributeEntriesCopied == copiedAttributes + 1)
        #expect(snapshotArena.snapshotGraphemeEntriesCopied == copiedGraphemes + 1)
#endif

        let unrelatedArena = CellArena()
        #expect(!snapshotArena.synchronizeSnapshotPrefix(from: unrelatedArena))
        #endif
    }

    @Test func snapshotArenaExtendsAcrossGraphemeBlockBoundary() throws {
        let arena = CellArena()
        for index in 0..<255 {
            _ = try #require(arena.intern(grapheme: [0x61, UInt32(0x300 + index)]))
        }
        let snapshot = arena.snapshotCopy()

        let id256 = try #require(arena.intern(grapheme: [0x62, 0x301]))
        let id257 = try #require(arena.intern(grapheme: [0x63, 0x301]))
        #expect(snapshot.synchronizeSnapshotPrefix(from: arena))
        #expect(snapshot.grapheme(for: id256) == [0x62, 0x301])
        #expect(snapshot.grapheme(for: id257) == [0x63, 0x301])
    }

    @Test func eraseRemovesSparseEntries() throws {
        let atom = try #require(TinyAtom.lookup(value: 7))
        defer { atom.release() }
        var value = CharData(attribute: CharData.defaultAttr, code: 0)
        value.setCharacter(Character("a\u{301}"), size: 1)
        value.setPayload(atom: atom)
        let page = CellStoragePage(count: 1)
        page.setCell(value, at: 0)

        #expect(page.graphemeCount == 1)
        #expect(page.payloadCount == 1)
        page.setCell(CharData.Null, at: 0)
        page.compactPresenceFlags()
        #expect(page.graphemeCount == 0)
        #expect(page.payloadCount == 0)
        #expect(!page.hasGraphemes)
        #expect(!page.hasPayloads)
    }

    @Test func styleCapacityUsesDefaultStyleAfterTheLimit() {
        let first = Attribute(fg: .ansi256(code: 1), bg: .defaultColor, style: .bold)
        let second = Attribute(fg: .ansi256(code: 2), bg: .defaultColor, style: .italic)
        let page = CellStoragePage(count: 1, styleCapacity: 1)
        page.setCell(CharData(attribute: first, code: 65), at: 0)

        let changed = page.replaceCell(at: 0, with: CharData(attribute: second, code: 66))

        #expect(changed)
        #expect(page.cell(at: 0).code == 66)
        #expect(page.cell(at: 0).attribute == CharData.defaultAttr)
        #expect(page.styleCount == 0)
    }

    @Test func graphemeCapacityUsesScalarFallbackAfterTheLimit() throws {
        let arena = CellArena(graphemeCapacity: 1)
        let first = try #require(arena.pack(styleID: 0,
                                            character: Character("a\u{301}"),
                                            widthState: .narrow))
        let second = try #require(arena.pack(styleID: 0,
                                             character: Character("b\u{301}"),
                                             widthState: .narrow))

        #expect(first.contentTag == .grapheme)
        #expect(second.contentTag == .codepoint)
        #expect(arena.character(for: second) == "b")
        #expect(arena.graphemeCount == 1)
    }

    @Test func packedAccessorsClampNarrowAndEmptyLines() {
        let narrow = BufferLine(cols: 1)
        narrow[0] = CharData(attribute: CharData.defaultAttr, code: 65)

        #expect(narrow.packedCode(at: -1) == 65)
        #expect(narrow.packedCode(at: 20) == 65)

        let empty = BufferLine(cols: 0)
        #expect(empty.packedCode(at: 0) == 0)
        #expect(empty.packedWidth(at: 0) == 1)
        #expect(empty.packedAttribute(at: 0) == CharData.defaultAttr)
    }

    @Test func terminalDegradesAfterAttributeArenaIsFull() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 2, rows: 2)
        var input = ""
        input.reserveCapacity(1_500_000)
        for value in 0...Int(UInt16.max) {
            input += "\u{1b}[38;2;\(value >> 8);\(value & 0xff);1mX"
        }

        terminal.feed(text: input)

        #expect(terminal.currentAttribute == CharData.defaultAttr)
    }
}
