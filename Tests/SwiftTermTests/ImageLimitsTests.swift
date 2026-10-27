#if !SWIFTTERM_EMBEDDED
import Testing

@testable import SwiftTerm

/// The size limits that Kitty graphics, inline images, Sixel and the portable
/// raster path share.
struct ImageLimitsTests {
    private func fits(_ width: Int, _ height: Int, bytesPerPixel: Int = 4,
                      maxDimension: Int = ImageLimits.maxDimension) -> Bool {
        ImageLimits.bitmapFits(width: width, height: height, bytesPerPixel: bytesPerPixel, maxDimension: maxDimension)
    }

    /// Uses cells of 10 × 20 and a screen of 80 × 25 cells.
    private func area(_ width: ImageSizeRequest, _ height: ImageSizeRequest, preserveAspectRatio: Bool = true,
                      natural: (width: Double, height: Double) = (200, 100), cellHeight: Double = 20,
                      letterbox: Bool = true) -> ImageArea? {
        ImageLimits.area(width: width, height: height, preserveAspectRatio: preserveAspectRatio,
                         naturalWidth: natural.width, naturalHeight: natural.height,
                         cellWidth: 10, cellHeight: cellHeight, columns: 80, rows: 25, letterbox: letterbox)
    }

    private func area(width: Double, height: Double, imageX: Double = 0, imageY: Double = 0,
                      imageWidth: Double? = nil, imageHeight: Double? = nil, rows: Int) -> ImageArea {
        ImageArea(width: width, height: height, imageX: imageX, imageY: imageY,
                  imageWidth: imageWidth ?? width, imageHeight: imageHeight ?? height, rows: rows)
    }

    // MARK: - Bitmaps

    @Test func bitmapChecksEachDimension() {
        #expect(fits(1, 1, maxDimension: 10))
        #expect(fits(10, 10, maxDimension: 10))
        #expect(!fits(11, 1, maxDimension: 10))
        #expect(!fits(1, 11, maxDimension: 10))
        for (width, height) in [(0, 1), (1, 0), (-1, 1), (1, -1), (Int.max, 1), (1, Int.max), (Int.min, Int.min)] {
            #expect(!fits(width, height, maxDimension: .max))
        }
        #expect(!fits(1, 1, bytesPerPixel: 0))
    }

    @Test func bitmapChecksTheBytes() {
        // 8000 × 8000 is 256 MB as RGBA8 and 512 MB with 16-bit samples.
        #expect(fits(8000, 8000, bytesPerPixel: 4))
        #expect(!fits(8000, 8000, bytesPerPixel: 8))
        // The product does not fit in an Int.
        #expect(!fits(Int.max / 2, 3, maxDimension: .max))
        #expect(ImageLimits.bitmapFits(width: 4, height: 4, bytesPerPixel: 4, maxDimension: 10, maxBytes: 64))
        #expect(!ImageLimits.bitmapFits(width: 4, height: 4, bytesPerPixel: 4, maxDimension: 10, maxBytes: 63))
    }

    @Test func inlineImagesPermitTallImages() {
        // A screenshot of a full web page is 115 MB as RGBA8. Kitty keeps the
        // limit of kitty for each dimension.
        #expect(fits(1200, 24_000))
        #expect(!fits(1200, 24_000, maxDimension: ImageLimits.kittyMaxDimension))
        #expect(fits(1, ImageLimits.maxDimension))
        #expect(!fits(1, ImageLimits.maxDimension + 1))
    }

    @Test func productReportsOverflow() {
        #expect(ImageLimits.product(3, 4, 5) == 60)
        #expect(ImageLimits.product(Int.max, 2) == nil)
        #expect(ImageLimits.product(Int.max / 2 + 1, 2, 0) == nil)
    }

    // MARK: - Area

    @Test func areaResolvesEachRequest() {
        #expect(area(.auto, .auto) == area(width: 200, height: 100, rows: 5))
        #expect(area(.cells(4), .cells(3), preserveAspectRatio: false) == area(width: 40, height: 60, rows: 3))
        #expect(area(.pixels(30), .pixels(41), preserveAspectRatio: false) == area(width: 30, height: 41, rows: 3))
        #expect(area(.percent(50), .percent(20), preserveAspectRatio: false) == area(width: 400, height: 100, rows: 5))
    }

    @Test func areaKeepsTheAspectRatio() {
        #expect(area(.cells(10), .auto) == area(width: 100, height: 50, rows: 3))
        #expect(area(.auto, .cells(1)) == area(width: 40, height: 20, rows: 1))
    }

    @Test func areaPutsTheImageInTheCenterOfARequestedArea() {
        // The image is two times as wide as it is high.
        #expect(area(.pixels(100), .pixels(100))
                == area(width: 100, height: 100, imageY: 25, imageWidth: 100, imageHeight: 50, rows: 5))
        #expect(area(.pixels(100), .pixels(400))
                == area(width: 100, height: 400, imageY: 175, imageWidth: 100, imageHeight: 50, rows: 20))
        #expect(area(.pixels(400), .pixels(100))
                == area(width: 400, height: 100, imageX: 100, imageWidth: 200, imageHeight: 100, rows: 5))
    }

    @Test func areaWithoutLetterboxHasTheSizeOfTheImage() {
        #expect(area(.pixels(100), .pixels(100), letterbox: false) == area(width: 100, height: 50, rows: 3))
        #expect(area(.pixels(400), .pixels(100), letterbox: false) == area(width: 200, height: 100, rows: 5))
    }

    @Test func areaRejectsSizesOutsideTheLimits() {
        let limit = ImageLimits.maxDimension
        #expect(area(.pixels(limit), .pixels(limit), preserveAspectRatio: false) != nil)
        #expect(area(.pixels(limit + 1), .pixels(1), preserveAspectRatio: false) == nil)
        #expect(area(.pixels(1), .pixels(limit + 1), preserveAspectRatio: false) == nil)
        #expect(area(.pixels(0), .pixels(1), preserveAspectRatio: false) == nil)
        #expect(area(.pixels(-1), .pixels(1), preserveAspectRatio: false) == nil)
        // A narrow image with a large width request has a large height.
        #expect(area(.cells(80), .auto, natural: (1, 4000)) == nil)
    }

    @Test func areaRejectsInvalidInputs() {
        let invalid: [Double] = [0, -1, .nan, .infinity, -.infinity]
        for value in invalid {
            #expect(area(.auto, .auto, natural: (value, 100)) == nil)
            #expect(area(.auto, .auto, natural: (100, value)) == nil)
            #expect(area(.auto, .auto, cellHeight: value) == nil)
        }
        // A cell height of less than 1 could give too many rows.
        #expect(area(.auto, .auto, cellHeight: 0.5) == nil)
    }

    @Test func areaRejectsTooManyRows() {
        func rows(cellHeight: Double) -> Int? {
            ImageLimits.area(width: .pixels(1), height: .pixels(ImageLimits.maxDimension),
                             preserveAspectRatio: false, naturalWidth: 1, naturalHeight: 1,
                             cellWidth: 1, cellHeight: cellHeight, columns: 1, rows: 1, letterbox: true)?.rows
        }
        // The tallest area fits with a cell height of 8 or more.
        #expect(rows(cellHeight: 8) == ImageLimits.maxRows)
        #expect(rows(cellHeight: 7.9) == nil)
        #expect(rows(cellHeight: 1) == nil)
    }

    @Test func aspectFitCentersTheImage() {
        let wide = ImageLimits.aspectFit(width: 200, height: 100, inWidth: 100, height: 100)
        #expect(wide == (0, 25, 100, 50))
        let tall = ImageLimits.aspectFit(width: 100, height: 200, inWidth: 100, height: 100)
        #expect(tall == (25, 0, 50, 100))
    }

    // MARK: - Portable raster path

    @Test func rasterImageHasTheTextureLimitsByDefault() {
        func make(width: Int, height: Int, maxDimension: Int? = nil, maxBytes: Int? = nil) -> TerminalRasterImage? {
            TerminalRasterImage(id: 1, width: width, height: height,
                                rgba: [UInt8](repeating: 255, count: 4 * width * height),
                                maxDimension: maxDimension, maxBytes: maxBytes)
        }
        #expect(make(width: 1, height: 16_384) != nil)
        #expect(make(width: 1, height: 16_385) == nil)
        #expect(make(width: 1, height: 16_385, maxDimension: 65_535) != nil)
        // A value larger than the limit of the views has no effect.
        #expect(make(width: 1, height: 65_536, maxDimension: 100_000) == nil)
        #expect(make(width: 2, height: 2, maxBytes: 15) == nil)
        #expect(make(width: 2, height: 2, maxBytes: 16) != nil)
        // 4,097 × 4,097 pixels are more than 64 MiB.
        #expect(make(width: 4_097, height: 4_097) == nil)
        #expect(make(width: 4_097, height: 4_097, maxBytes: ImageLimits.maxBitmapBytes) != nil)
    }

    @Test func rasterImageRejectsALargeAreaWithoutChanges() throws {
        let terminal = Terminal(delegate: TerminalTestDelegate())
        let image = try #require(TerminalRasterImage(id: 1, width: 1, height: 4000,
                                                     rgba: [UInt8](repeating: 255, count: 4 * 4000)))
        // 80 cells of 10 pixels make the image 3.2 million pixels high.
        #expect(!terminal.insertRasterImage(image, cellWidth: 10, cellHeight: 20, width: .cells(80)))
        #expect(terminal.buffer.y == 0 && !terminal.buffer.hasAnyImages)
        #expect(terminal.insertRasterImage(image, cellWidth: 10, cellHeight: 20, width: .cells(1)))
        #expect(terminal.buffer.hasAnyImages)
    }

    // MARK: - Stripes

    @Test func stripesCountTheScale() throws {
        // 10,000 × 10,000 points use 400 MB at scale 1 and 1.6 GB at scale 2.
        let large = try #require(area(.pixels(10_000), .pixels(10_000), preserveAspectRatio: false))
        #expect(ImageLimits.stripesFit(large, cellHeight: 20, scale: 1))
        #expect(!ImageLimits.stripesFit(large, cellHeight: 20, scale: 2))
        let small = try #require(area(.pixels(5_000), .pixels(5_000), preserveAspectRatio: false))
        #expect(ImageLimits.stripesFit(small, cellHeight: 20, scale: 2))
        for scale in [0, -1, Double.nan, .infinity] {
            #expect(!ImageLimits.stripesFit(small, cellHeight: 20, scale: scale))
        }
    }

    @Test func stripesCountOnlyTheTextureWidth() throws {
        // At scale 2, a full stripe of 120,000 × 40 pixels for each of the
        // 100 rows is 1.9 GB. A stripe keeps only 8,192 pixels: 131 MB.
        let wide = try #require(area(.pixels(60_000), .pixels(2_000), preserveAspectRatio: false))
        #expect(ImageLimits.stripesFit(wide, cellHeight: 20, scale: 2))
        #expect(ImageLimits.stripeWidth(wide.width, scale: 2) == ImageLimits.maxStripeWidth)
        #expect(ImageLimits.stripeWidth(100.5, scale: 2) == 201)
    }

    @Test func pixelsRoundUpToAtLeastOne() {
        #expect(ImageLimits.pixels(10.2, scale: 2) == 21)
        #expect(ImageLimits.pixels(10, scale: 3) == 30)
        #expect(ImageLimits.pixels(0.1, scale: 1) == 1)
    }
}
#endif
