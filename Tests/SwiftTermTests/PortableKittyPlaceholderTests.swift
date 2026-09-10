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
}
