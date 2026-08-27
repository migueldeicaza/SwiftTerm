//
//  KittyGraphicsSnapshot.swift
//  SwiftTerm
//

import Foundation

/// The three Kitty graphics layers relative to cell backgrounds and text.
enum KittyGraphicsRenderLayer: Sendable, Equatable {
    /// Kitty reserves the lower half of the signed z-index range for images
    /// that must stay behind cell backgrounds.
    static let backgroundThreshold = Int32.min / 2

    case belowBackground
    case belowText
    case aboveText

    init(zIndex: Int32) {
        if zIndex < Self.backgroundThreshold {
            self = .belowBackground
        } else if zIndex < 0 {
            self = .belowText
        } else {
            self = .aboveText
        }
    }
}

/// A pixel rectangle in a Kitty graphics image.
public struct KittyGraphicsPixelRect: Sendable, Hashable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Resolved screen-cell geometry for a Kitty graphics placement.
public struct KittyGraphicsCellGeometry: Sendable, Hashable {
    public let column: Int
    public let row: Int
    public let columns: Int
    public let rows: Int

    public init(column: Int, row: Int, columns: Int, rows: Int) {
        self.column = column
        self.row = row
        self.columns = columns
        self.rows = rows
    }
}

/// Immutable decoded image data for a renderer.
public struct KittyGraphicsRenderImage: Sendable, Hashable {
    public let imageId: UInt32
    public let imageNumber: UInt32?
    public let width: Int
    public let height: Int
    /// Canonical, row-major, straight-alpha RGBA8 pixels.
    ///
    /// An array, not `Data`, so that a snapshot shares the terminal's decoded
    /// pixels by reference. A `Data(...)` conversion here would copy every
    /// pixel of every live image on every frame. The payload is immutable once
    /// decoded, and `contentGeneration` tells a consumer when it changed, so
    /// sharing is safe.
    public let rgba: [UInt8]
    /// Changes when the pixels of the displayed frame change.
    public let contentGeneration: UInt64

    public init(
        imageId: UInt32,
        imageNumber: UInt32?,
        width: Int,
        height: Int,
        rgba: [UInt8],
        contentGeneration: UInt64
    ) {
        self.imageId = imageId
        self.imageNumber = imageNumber
        self.width = width
        self.height = height
        self.rgba = rgba
        self.contentGeneration = contentGeneration
    }
}

/// Immutable placement geometry for a renderer.
public struct KittyGraphicsRenderPlacement: Sendable, Hashable {
    /// A terminal-assigned stable token. Anonymous placements also have a token.
    public let token: UInt64
    /// The client placement ID, or zero for an anonymous placement.
    public let placementId: UInt32
    public let imageId: UInt32
    public let visibleSource: KittyGraphicsPixelRect
    public let geometry: KittyGraphicsCellGeometry
    public let pixelOffsetX: Int
    public let pixelOffsetY: Int
    public let zIndex: Int32
    public let isVirtual: Bool
    public let insertionOrder: UInt64

    public init(
        token: UInt64,
        placementId: UInt32,
        imageId: UInt32,
        visibleSource: KittyGraphicsPixelRect,
        geometry: KittyGraphicsCellGeometry,
        pixelOffsetX: Int,
        pixelOffsetY: Int,
        zIndex: Int32,
        isVirtual: Bool,
        insertionOrder: UInt64
    ) {
        self.token = token
        self.placementId = placementId
        self.imageId = imageId
        self.visibleSource = visibleSource
        self.geometry = geometry
        self.pixelOffsetX = pixelOffsetX
        self.pixelOffsetY = pixelOffsetY
        self.zIndex = zIndex
        self.isVirtual = isVirtual
        self.insertionOrder = insertionOrder
    }
}

/// Immutable Kitty graphics renderer input.
public struct KittyGraphicsRenderSnapshot: Sendable, Hashable {
    /// Changes after any storage or placement mutation.
    public let storageGeneration: UInt64
    public let imagesById: [UInt32: KittyGraphicsRenderImage]
    /// Placements sorted by z-index and insertion order.
    public let placements: [KittyGraphicsRenderPlacement]

    public init(
        storageGeneration: UInt64,
        imagesById: [UInt32: KittyGraphicsRenderImage],
        placements: [KittyGraphicsRenderPlacement]
    ) {
        self.storageGeneration = storageGeneration
        self.imagesById = imagesById
        self.placements = placements
    }
}
