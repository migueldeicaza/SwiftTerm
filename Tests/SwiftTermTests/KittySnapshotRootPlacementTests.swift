import Foundation
import Testing

@testable import SwiftTerm

struct KittySnapshotRootPlacementTests {
    private func send(_ terminal: Terminal, control: String, payload: [UInt8] = []) {
        terminal.feed(text: "\u{1b}_G\(control);\(Data(payload).base64EncodedString())\u{1b}\\")
    }

    @Test func rootsAndRelativeChainsFollowParentAndViewportChanges() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 20)
        let pixels: [UInt8] = [1, 2, 3, 255, 4, 5, 6, 255,
                               7, 8, 9, 255, 10, 11, 12, 255]
        terminal.feed(text: "\u{1b}[4;3H")
        send(terminal,
             control: "a=T,f=32,s=2,v=2,i=1,p=1,c=2,r=3,C=1,z=2,x=1,y=1,w=1,h=1",
             payload: pixels)
        send(terminal,
             control: "a=T,f=32,s=1,v=1,i=2,p=1,P=1,Q=1,H=2,V=1,c=1,r=1,C=1,z=-1",
             payload: [20, 21, 22, 255])
        send(terminal,
             control: "a=T,f=32,s=1,v=1,i=3,p=1,P=2,Q=1,H=3,V=2,c=1,r=1,C=1,z=-1",
             payload: [30, 31, 32, 255])
        send(terminal,
             control: "a=T,f=32,s=1,v=1,i=4,p=1,P=1,Q=1,H=1,V=3,c=1,r=1,C=1,z=0",
             payload: [40, 41, 42, 255])
        terminal.feed(text: "\u{1b}[8;9H")
        send(terminal,
             control: "a=T,f=32,s=1,v=1,i=5,p=1,c=1,r=1,C=1,z=2",
             payload: [50, 51, 52, 255])

        let before = terminal.kittyGraphicsRenderSnapshot()
        #expect(before.placements.map(\.imageId) == [2, 3, 4, 1, 5])
        #expect(before.placements.map(\.geometry) == [
            KittyGraphicsCellGeometry(column: 4, row: 4, columns: 1, rows: 1),
            KittyGraphicsCellGeometry(column: 7, row: 6, columns: 1, rows: 1),
            KittyGraphicsCellGeometry(column: 3, row: 6, columns: 1, rows: 1),
            KittyGraphicsCellGeometry(column: 2, row: 3, columns: 2, rows: 3),
            KittyGraphicsCellGeometry(column: 8, row: 7, columns: 1, rows: 1)
        ])
        let root = try #require(before.placements.first { $0.imageId == 1 })
        #expect(root.visibleSource == KittyGraphicsPixelRect(x: 1, y: 1, width: 1, height: 1))
        #expect(before.imagesById[1]?.rgba == pixels)

        let parentKey = KittyPlacementKey(imageId: 1, placementId: 1)
        var parent = try #require(terminal.kittyGraphicsState.placementsByKey[parentKey])
        parent.row = 9
        parent.col = 5
        terminal.kittyGraphicsState.placementsByKey[parentKey] = parent
        terminal.buffer.yDisp = 2

        let after = terminal.kittyGraphicsRenderSnapshot()
        #expect(after.imagesById == before.imagesById)
        #expect(after.placements.map(\.imageId) == [2, 3, 4, 1, 5])
        #expect(after.placements.map(\.geometry) == [
            KittyGraphicsCellGeometry(column: 7, row: 8, columns: 1, rows: 1),
            KittyGraphicsCellGeometry(column: 10, row: 10, columns: 1, rows: 1),
            KittyGraphicsCellGeometry(column: 6, row: 10, columns: 1, rows: 1),
            KittyGraphicsCellGeometry(column: 5, row: 7, columns: 2, rows: 3),
            KittyGraphicsCellGeometry(column: 8, row: 5, columns: 1, rows: 1)
        ])
        #expect(after.placements.map(\.visibleSource) == before.placements.map(\.visibleSource))
        #expect(after.placements.map(\.token) == before.placements.map(\.token))
        #expect(after.placements.map(\.zIndex) == [-1, -1, 0, 2, 2])
    }

    @Test func incompleteParentMetadataUsesStoredRootPosition() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 20)
        terminal.feed(text: "\u{1b}[6;4H")
        send(terminal,
             control: "a=T,f=32,s=1,v=1,i=1,p=1,c=1,r=1,C=1",
             payload: [1, 2, 3, 255])
        let key = KittyPlacementKey(imageId: 1, placementId: 1)
        let original = try #require(terminal.kittyGraphicsState.placementsByKey[key])
        let expected = terminal.kittyGraphicsRenderSnapshot()

        let parentImageIds: [UInt32?] = [nil, 999]
        for imageId in parentImageIds {
            // An incomplete parent link must use the stored root position.
            terminal.kittyGraphicsState.placementsByKey[key] = withParent(
                original, imageId: imageId, placementId: imageId == nil ? 999 : nil)
            #expect(terminal.kittyGraphicsRenderSnapshot() == expected)
        }

        var virtual = original
        virtual.isVirtual = true
        terminal.kittyGraphicsState.placementsByKey[key] = virtual
        let snapshot = terminal.kittyGraphicsRenderSnapshot()
        #expect(snapshot.placements.first?.geometry == expected.placements.first?.geometry)
        #expect(snapshot.placements.first?.isVirtual == true)
    }

    @Test(arguments: [false, true])
    func rejectsWrongScreenRootsAndKeepsUnplacedImages(alternate: Bool) throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        if alternate {
            terminal.feed(text: "\u{1b}[?1049h")
        }
        send(terminal,
             control: "a=T,f=32,s=1,v=1,i=1,p=1,c=1,r=1,C=1",
             payload: [1, 2, 3, 255])
        send(terminal,
             control: "a=t,f=32,s=1,v=1,i=2",
             payload: [4, 5, 6, 255])
        let before = terminal.kittyGraphicsRenderSnapshot()
        #expect(before.placements.map(\.imageId) == [1])
        #expect(before.imagesById[2]?.rgba == [4, 5, 6, 255])

        let key = KittyPlacementKey(imageId: 1, placementId: 1)
        var record = try #require(terminal.kittyGraphicsState.placementsByKey[key])
        record.isAlternateBuffer = !alternate
        terminal.kittyGraphicsState.placementsByKey[key] = record
        let after = terminal.kittyGraphicsRenderSnapshot()
        #expect(after.placements.isEmpty)
        #expect(after.imagesById == before.imagesById)
    }

    private func withParent(
        _ record: KittyPlacementRecord,
        imageId: UInt32?,
        placementId: UInt32?
    ) -> KittyPlacementRecord {
        KittyPlacementRecord(
            token: record.token,
            imageId: record.imageId,
            clientPlacementId: record.clientPlacementId,
            placementId: record.placementId,
            parentImageId: imageId,
            parentPlacementId: placementId,
            parentPlacementIsAnonymous: record.parentPlacementIsAnonymous,
            parentOffsetH: record.parentOffsetH,
            parentOffsetV: record.parentOffsetV,
            pixelOffsetX: record.pixelOffsetX,
            pixelOffsetY: record.pixelOffsetY,
            col: record.col,
            row: record.row,
            cols: record.cols,
            rows: record.rows,
            zIndex: record.zIndex,
            isVirtual: record.isVirtual,
            isAlternateBuffer: record.isAlternateBuffer,
            sourceX: record.sourceX,
            sourceY: record.sourceY,
            sourceWidth: record.sourceWidth,
            sourceHeight: record.sourceHeight,
            insertionOrder: record.insertionOrder)
    }
}
