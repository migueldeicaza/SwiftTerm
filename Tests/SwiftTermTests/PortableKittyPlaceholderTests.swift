import Foundation
import Testing
@testable import SwiftTerm

struct PortableKittyPlaceholderTests {
    @Test func virtualPlacementNeedsVisiblePlaceholderAndFitsEachCell() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 8, rows: 4)
        let pixels = Data([255, 0, 0, 255, 0, 255, 0, 255]).base64EncodedString()
        terminal.feed(text: "\u{1b}_Ga=T,f=32,s=2,v=1,i=1,p=7,c=2,r=1,U=1,C=1;\(pixels)\u{1b}\\")
        func placements() -> [TerminalKittyPlaceholderPlacement] {
            terminal.terminalLock.withLock {
                terminal.visibleKittyPlaceholderPlacements(snapshot: terminal.kittyGraphicsRenderSnapshot(),
                                                          cellWidth: 10, cellHeight: 20)
            }
        }
        #expect(placements().isEmpty)
        // The second placeholder inherits the next source column.
        terminal.feed(text: "\u{1b}[38;2;0;0;1m\u{1b}[58;2;0;0;7m\u{10EEEE}\u{10EEEE}")
        let crops = placements()
        #expect(crops.count == 2)
        guard crops.count == 2 else { return }
        #expect(crops[0].source.x == 0 && crops[0].source.width == 1)
        #expect(crops[1].source.x == 1 && crops[1].source.width == 1)
        #expect(crops[0].destination.x == 0 && crops[1].destination.x == 10)
        #expect(crops.allSatisfy { $0.destination.y == 5 && $0.destination.height == 10 && $0.imageId == 1 })
        terminal.feed(text: "\u{1b}[H\u{1b}[58;2;0;0;8m\u{10EEEE}\u{10EEEE}")
        #expect(placements().isEmpty)
    }

    @Test(arguments: [3, 9])
    func positiveVerticalOffsetMovesDownAndClipsTheSource(offset: Int) throws {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 8, rows: 4)
        delegate.cellSizeInPixelsValue = (10, 20)
        let pixels = Data([255, 0, 0, 255, 0, 255, 0, 255]).base64EncodedString()
        terminal.feed(text: "\u{1b}_Ga=T,f=32,s=2,v=1,i=1,p=7,c=2,r=1,U=1,C=1,Y=\(offset);\(pixels)\u{1b}\\")
        terminal.feed(text: "\u{1b}[38;2;0;0;1m\u{1b}[58;2;0;0;7m\u{10EEEE}\u{10EEEE}")
        let crops = terminal.terminalLock.withLock {
            terminal.visibleKittyPlaceholderPlacements(snapshot: terminal.kittyGraphicsRenderSnapshot(),
                                                      cellWidth: 10, cellHeight: 20)
        }
        #expect(crops.count == 2)
        let crop = try #require(crops.first)
        let top = Double(5 + offset)
        let height = min(10.0, 20 - top)
        #expect(crop.destination.y == top)
        #expect(crop.destination.height == height)
        #expect(crop.source.y == 0)
        #expect(abs(crop.source.height - height / 10) < 0.000001)
        #expect(crops.allSatisfy { $0.destination.y >= 0 && $0.destination.y + $0.destination.height <= 20 })
    }

    @Test func packedScanKeepsGraphemeCoordinatesAndBreaksInheritanceAtText() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 8, rows: 4)
        let pixels = Data(repeating: 255, count: 12).base64EncodedString()
        terminal.feed(text: "\u{1b}_Ga=T,f=32,s=3,v=1,i=1,p=7,c=3,r=1,U=1,C=1;\(pixels)\u{1b}\\")
        terminal.feed(text: "\u{1b}[38;2;0;0;1m\u{1b}[58;2;0;0;7m\u{10EEEE}\u{0305}\u{030D}x\u{10EEEE}")
        let crops = terminal.terminalLock.withLock {
            terminal.visibleKittyPlaceholderPlacements(snapshot: terminal.kittyGraphicsRenderSnapshot(),
                                                      cellWidth: 10, cellHeight: 20)
        }
        #expect(crops.count == 2)
        guard crops.count == 2 else { return }
        #expect(crops[0].source.x == 1)
        #expect(crops[1].source.x == 0, "Ordinary text breaks implicit column inheritance.")
        #expect(crops[0].destination.x == 0 && crops[1].destination.x == 20)
    }

    @Test func scalarDecoderMatchesCharacterDecoderWithExtraMarks() throws {
        let attribute = Attribute(fg: .trueColor(red: 0, green: 0, blue: 1), bg: .defaultColor, style: .none)
        let scalars: [UInt32] = [KittyPlaceholder.baseScalar, 0x0305, 0x030D, 0x030E, 0x0305, 0x030D]
        let character = Character(String(String.UnicodeScalarView(scalars.compactMap(Unicode.Scalar.init))))
        let expected = try #require(KittyPlaceholderDecoder.decode(character: character, attribute: attribute,
            row: 2, col: 3, previous: nil, previousAttribute: nil))
        let actual = try #require(KittyPlaceholderDecoder.decode(scalars: scalars, attribute: attribute,
            row: 2, col: 3, previous: nil, previousAttribute: nil))
        #expect(actual.placeholderRow == expected.placeholderRow && actual.placeholderRow == 0)
        #expect(actual.placeholderCol == expected.placeholderCol && actual.placeholderCol == 1)
        #expect(actual.imageId == expected.imageId && actual.imageId == 0x02000001)
    }

}
