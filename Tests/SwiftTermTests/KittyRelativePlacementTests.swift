//
//  KittyRelativePlacementTests.swift
//
#if os(macOS)
import Testing

@testable import SwiftTerm

final class KittyRelativePlacementTests {
    private final class TestKittyImage: KittyPlacementImage {
        let pixelWidth: Int
        let pixelHeight: Int
        var col: Int

        var kittyIsKitty: Bool = true
        var kittyImageId: UInt32?
        var kittyImageNumber: UInt32?
        var kittyPlacementId: UInt32?
        var kittyZIndex: Int = 0
        var kittyCol: Int = 0
        var kittyRow: Int = 0
        var kittyCols: Int = 1
        var kittyRows: Int = 1
        var kittyPixelOffsetX: Int = 0
        var kittyPixelOffsetY: Int = 0

        init(imageId: UInt32, placementId: UInt32, col: Int, row: Int) {
            self.pixelWidth = 1
            self.pixelHeight = 1
            self.col = col
            self.kittyImageId = imageId
            self.kittyPlacementId = placementId
            self.kittyCol = col
            self.kittyRow = row
        }
    }

    private func makeHeadlessTerminal() -> HeadlessTerminal {
        HeadlessTerminal(queue: SwiftTermTests.queue, options: TerminalOptions(cols: 10, rows: 10)) { _ in }
    }

    @Test func testRelativePlacementFollowsParentMovement() {
        let h = makeHeadlessTerminal()
        let t = h.terminal!

        let parentRow = 2
        let parentCol = 1
        let parentImage = TestKittyImage(imageId: 1, placementId: 1, col: parentCol, row: parentRow)
        t.buffer.lines[parentRow].attach(image: parentImage)
        t.registerKittyPlacement(imageId: 1,
                                 placementId: 1,
                                 parentImageId: nil,
                                 parentPlacementId: nil,
                                 parentOffsetH: 0,
                                 parentOffsetV: 0,
                                 pixelOffsetX: 0,
                                 pixelOffsetY: 0,
                                 col: parentCol,
                                 row: parentRow,
                                 cols: 1,
                                 rows: 1,
                                 zIndex: 0,
                                 isVirtual: false)

        let childRow = parentRow + 1
        let childCol = parentCol + 2
        let childImage = TestKittyImage(imageId: 2, placementId: 1, col: childCol, row: childRow)
        t.buffer.lines[childRow].attach(image: childImage)
        t.registerKittyPlacement(imageId: 2,
                                 placementId: 1,
                                 parentImageId: 1,
                                 parentPlacementId: 1,
                                 parentOffsetH: 2,
                                 parentOffsetV: 1,
                                 pixelOffsetX: 0,
                                 pixelOffsetY: 0,
                                 col: childCol,
                                 row: childRow,
                                 cols: 1,
                                 rows: 1,
                                 zIndex: 0,
                                 isVirtual: false)

        let newParentRow = 4
        let newParentCol = 2
        t.buffer.lines[parentRow].images = nil
        parentImage.col = newParentCol
        parentImage.kittyCol = newParentCol
        parentImage.kittyRow = newParentRow
        t.buffer.lines[newParentRow].attach(image: parentImage)

        t.updateKittyRelativePlacementsForCurrentBuffer()

        let newChildRow = newParentRow + 1
        let newChildCol = newParentCol + 2
        let movedChild = t.buffer.lines[newChildRow].images?.contains(where: { image in
            guard let kitty = image as? KittyPlacementImage else {
                return false
            }
            return kitty.kittyImageId == 2 && kitty.kittyPlacementId == 1
        }) ?? false
        #expect(movedChild)
        #expect(childImage.col == newChildCol)
        #expect(childImage.kittyCol == newChildCol)
        #expect(childImage.kittyRow == newChildRow)
    }
}
#endif
