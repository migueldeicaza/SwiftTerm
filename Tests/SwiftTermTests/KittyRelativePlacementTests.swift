//
//  KittyRelativePlacementTests.swift
//
import Foundation
import Testing

@testable import SwiftTerm

final class KittyRelativePlacementTests {
    private func send(
        _ terminal: Terminal,
        control: String,
        payload: [UInt8] = []
    ) {
        terminal.feed(text: "\u{1b}_G\(control);\(Data(payload).base64EncodedString())\u{1b}\\")
    }

    @Test func testRelativePlacementFollowsParentMovement() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 10)
        terminal.feed(text: "\u{1b}[3;2H")
        send(terminal,
             control: "a=T,f=24,s=1,v=1,i=1,p=1,c=1,r=1,C=1",
             payload: [1, 2, 3])
        send(terminal,
             control: "a=T,f=24,s=1,v=1,i=2,p=1,P=1,Q=1,H=2,V=1,c=1,r=1,C=1",
             payload: [4, 5, 6])

        var snapshot = terminal.kittyGraphicsRenderSnapshot()
        let initialParent = try #require(snapshot.placements.first { $0.imageId == 1 })
        let initialChild = try #require(snapshot.placements.first { $0.imageId == 2 })
        #expect(initialParent.geometry.column == 1)
        #expect(initialParent.geometry.row == 2)
        #expect(initialChild.geometry.column == 3)
        #expect(initialChild.geometry.row == 3)

        terminal.scrollKittyPlacementsInMargins(
            top: 0, bottom: 8, left: 0, right: 9, delta: 2)
        snapshot = terminal.kittyGraphicsRenderSnapshot()
        let movedParent = try #require(snapshot.placements.first { $0.imageId == 1 })
        let movedChild = try #require(snapshot.placements.first { $0.imageId == 2 })
        #expect(movedParent.geometry.column == 1)
        #expect(movedParent.geometry.row == 4)
        #expect(movedChild.geometry.column == 3)
        #expect(movedChild.geometry.row == 5)
    }
}
