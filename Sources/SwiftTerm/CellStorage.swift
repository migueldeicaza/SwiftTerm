//
//  CellStorage.swift
//  SwiftTerm
//
//  Stores terminal cells in one 64-bit value. Uncommon immutable values live
//  in an arena that is shared by all lines of a terminal.
//

import Foundation

/// The fixed-size value that SwiftTerm stores for each terminal cell.
///
/// The identifiers in this value are valid only with the matching
/// ``CellArena``. Lines in one terminal share an arena, so cells can move
/// between those lines without conversion.
struct PackedCell: Hashable, Sendable {
    public enum ContentTag: UInt8, Sendable {
        case codepoint = 0
        case grapheme = 1
        case backgroundPalette = 2
        case backgroundRGB = 3
    }

    public enum WidthState: UInt8, Sendable {
        case narrow = 0
        case wide = 1
        case spacerTail = 2
        case spacerHead = 3
    }

    public private(set) var rawValue: UInt64

    public init(rawValue: UInt64 = 0) {
        self.rawValue = rawValue
    }

    public static let contentTagShift: UInt64 = 0
    public static let contentShift: UInt64 = 2
    public static let styleIDShift: UInt64 = 26
    public static let widthStateShift: UInt64 = 42
    public static let protectedShift: UInt64 = 44
    public static let payloadShift: UInt64 = 45
    public static let semanticContentShift: UInt64 = 61

    public static let contentTagMask: UInt64 = ((1 << 2) - 1) << contentTagShift
    public static let contentMask: UInt64 = ((1 << 24) - 1) << contentShift
    public static let styleIDMask: UInt64 = ((1 << 16) - 1) << styleIDShift
    public static let widthStateMask: UInt64 = ((1 << 2) - 1) << widthStateShift
    public static let protectedMask: UInt64 = 1 << protectedShift
    public static let payloadMask: UInt64 = ((1 << 16) - 1) << payloadShift
    public static let semanticContentMask: UInt64 = ((1 << 3) - 1) << semanticContentShift

    @inline(__always)
    public var contentTag: ContentTag {
        switch UInt8((rawValue & Self.contentTagMask) >> Self.contentTagShift) {
        case 0: return .codepoint
        case 1: return .grapheme
        case 2: return .backgroundPalette
        default: return .backgroundRGB
        }
    }

    @inline(__always)
    public var content: UInt32 {
        UInt32((rawValue & Self.contentMask) >> Self.contentShift)
    }

    @inline(__always)
    public var styleID: UInt16 {
        UInt16((rawValue & Self.styleIDMask) >> Self.styleIDShift)
    }

    @inline(__always)
    public var widthState: WidthState {
        switch UInt8((rawValue & Self.widthStateMask) >> Self.widthStateShift) {
        case 0: return .narrow
        case 1: return .wide
        case 2: return .spacerTail
        default: return .spacerHead
        }
    }

    @inline(__always)
    public var isProtected: Bool {
        rawValue & Self.protectedMask != 0
    }

    @inline(__always)
    public var payloadCode: UInt16 {
        UInt16((rawValue & Self.payloadMask) >> Self.payloadShift)
    }

    @inline(__always)
    public var hasPayload: Bool {
        payloadCode != 0
    }

    @inline(__always)
    public var semanticContentCode: UInt8 {
        UInt8((rawValue & Self.semanticContentMask) >> Self.semanticContentShift)
    }

    /// The attribute identity used by internal renderer caches.
    ///
    /// Normal text uses its arena style identifier. Blank cells that encode a
    /// palette or RGB background inline use the background value instead.
    @inline(__always)
    var attributeKey: PackedAttributeKey {
        switch contentTag {
        case .codepoint, .grapheme:
            return PackedAttributeKey(rawValue: UInt32(styleID))
        case .backgroundPalette:
            return PackedAttributeKey(rawValue: (1 << 24) | content)
        case .backgroundRGB:
            return PackedAttributeKey(rawValue: (2 << 24) | content)
        }
    }

    /// True when all fields contain values that an arena can decode.
    public var hasValidEncoding: Bool {
        guard semanticContentCode < 7 else {
            return false
        }

        switch contentTag {
        case .codepoint:
            return Self.isValidUnicodeScalar(content)
        case .grapheme:
            return content != 0
        case .backgroundPalette:
            return content <= UInt8.max
        case .backgroundRGB:
            return true
        }
    }

    /// Creates a cell only when the raw value has a valid in-memory encoding.
    public init?(validatingRawValue rawValue: UInt64) {
        let value = PackedCell(rawValue: rawValue)
        guard value.hasValidEncoding else {
            return nil
        }
        self = value
    }

    static func make(contentTag: ContentTag, content: UInt32, styleID: UInt16,
                     widthState: WidthState, isProtected: Bool,
                     payloadCode: UInt16, semanticContentCode: UInt8) -> PackedCell?
    {
        guard content <= 0x00ff_ffff, semanticContentCode < 7 else {
            return nil
        }

        var rawValue = UInt64(contentTag.rawValue) << contentTagShift
        rawValue |= UInt64(content) << contentShift
        rawValue |= UInt64(styleID) << styleIDShift
        rawValue |= UInt64(widthState.rawValue) << widthStateShift
        if isProtected {
            rawValue |= protectedMask
        }
        rawValue |= UInt64(payloadCode) << payloadShift
        rawValue |= UInt64(semanticContentCode) << semanticContentShift
        return PackedCell(validatingRawValue: rawValue)
    }

    /// Constructs a cell from values that have already been checked by the
    /// terminal-owned packed path.
    @inline(__always)
    static func makeUnchecked(contentTag: ContentTag, content: UInt32, styleID: UInt16,
                              widthState: WidthState, isProtected: Bool,
                              payloadCode: UInt16,
                              semanticContentCode: UInt8) -> PackedCell
    {
        var rawValue = UInt64(contentTag.rawValue) << contentTagShift
        rawValue |= UInt64(content) << contentShift
        rawValue |= UInt64(styleID) << styleIDShift
        rawValue |= UInt64(widthState.rawValue) << widthStateShift
        if isProtected {
            rawValue |= protectedMask
        }
        rawValue |= UInt64(payloadCode) << payloadShift
        rawValue |= UInt64(semanticContentCode) << semanticContentShift
        return PackedCell(rawValue: rawValue)
    }

    /// Compatibility helper for callers that only need a payload-presence bit.
    static func make(contentTag: ContentTag, content: UInt32, styleID: UInt16,
                     widthState: WidthState, isProtected: Bool,
                     hasPayload: Bool, semanticContentCode: UInt8) -> PackedCell?
    {
        make(contentTag: contentTag, content: content, styleID: styleID,
             widthState: widthState, isProtected: isProtected,
             payloadCode: hasPayload ? 1 : 0,
             semanticContentCode: semanticContentCode)
    }

    static func isValidUnicodeScalar(_ value: UInt32) -> Bool {
        value <= 0x10ffff && !(0xd800...0xdfff).contains(value)
    }

    @inline(__always)
    func replacingPayloadCode(_ code: UInt16) -> PackedCell {
        PackedCell(rawValue: (rawValue & ~Self.payloadMask) |
                   (UInt64(code) << Self.payloadShift))
    }

    @inline(__always)
    func replacingSemanticContentCode(_ code: UInt8) -> PackedCell {
        precondition(code < 7, "Invalid semantic-content code")
        return PackedCell(rawValue: (rawValue & ~Self.semanticContentMask) |
                          (UInt64(code) << Self.semanticContentShift))
    }

    @inline(__always)
    func replacingProtection(_ protected: Bool) -> PackedCell {
        let value = protected ? rawValue | Self.protectedMask : rawValue & ~Self.protectedMask
        return PackedCell(rawValue: value)
    }
}

/// A compact attribute identity within one terminal's cell arena.
///
/// The renderer already knows which terminal owns a snapshot. It can therefore
/// compare and hash this value without expanding and hashing `Attribute`.
struct PackedAttributeKey: Hashable, Sendable {
    let rawValue: UInt32
}

/// Stable lookup data shared by packed cells in one terminal.
///
/// Entries are immutable and identifiers are never reused. This permits a raw
/// packed cell to remain valid after it moves to another line or snapshot.
final class CellArena {
    private static let graphemeBlockSize = 256
    private static let maximumGraphemeID = 0x00ff_ffff
    /// Keep the intern table bounded. Packed cells keep stable identifiers, so
    /// entries cannot be evicted while lines or snapshots can still refer to
    /// them. New clusters degrade to their first scalar after this limit.
    private static let defaultGraphemeCapacity = Int(UInt16.max)

    private let attributeCapacity: Int
    private let attributes: UnsafeMutablePointer<Attribute>
    private var attributeCountValue = 1
    private var attributeIdentifiers: [Attribute: UInt16] = [:]

    private let graphemeBlocks: UnsafeMutablePointer<UnsafeMutablePointer<[UInt32]?>?>
    private let graphemeCapacity: Int
    private let graphemeBlockCapacity: Int
    private var allocatedGraphemeBlockCount = 0
    private var graphemeCountValue: UInt32 = 0
    private var graphemeIdentifiers: [[UInt32]: UInt32] = [:]

    init(styleCapacity: Int = Int(UInt16.max),
         graphemeCapacity: Int = CellArena.defaultGraphemeCapacity) {
        attributeCapacity = min(max(styleCapacity, 0), Int(UInt16.max))
        attributes = .allocate(capacity: attributeCapacity + 1)
        attributes.initialize(to: CharData.defaultAttr)
        attributeIdentifiers[CharData.defaultAttr] = 0

        self.graphemeCapacity = min(max(graphemeCapacity, 0), Self.maximumGraphemeID)
        graphemeBlockCapacity = max(1, (self.graphemeCapacity + Self.graphemeBlockSize - 1) /
            Self.graphemeBlockSize)
        graphemeBlocks = .allocate(capacity: graphemeBlockCapacity)
        graphemeBlocks.initialize(repeating: nil, count: graphemeBlockCapacity)
    }

    deinit {
        attributes.deinitialize(count: attributeCountValue)
        attributes.deallocate()

        for blockIndex in 0..<allocatedGraphemeBlockCount {
            if let block = graphemeBlocks[blockIndex] {
                block.deinitialize(count: Self.graphemeBlockSize)
                block.deallocate()
            }
        }
        graphemeBlocks.deinitialize(count: graphemeBlockCapacity)
        graphemeBlocks.deallocate()
    }

    var attributeCount: Int { attributeCountValue - 1 }
    var graphemeCount: Int { Int(graphemeCountValue) }

    func intern(attribute: Attribute) -> UInt16? {
        if let identifier = attributeIdentifiers[attribute] {
            return identifier
        }
        guard attributeCountValue <= attributeCapacity else {
            return nil
        }

        let identifier = UInt16(attributeCountValue)
        attributes.advanced(by: attributeCountValue).initialize(to: attribute)
        attributeCountValue += 1
        attributeIdentifiers[attribute] = identifier
        return identifier
    }

    /// Creates a scalar cell from an attribute identifier that is already
    /// owned by this arena. This is the main parser path.
    @inline(__always)
    func pack(styleID: UInt16, scalar: UInt32,
              widthState: PackedCell.WidthState,
              payloadCode: UInt16 = 0, semanticContentCode: UInt8 = 0,
              isProtected: Bool = false) -> PackedCell?
    {
        guard PackedCell.isValidUnicodeScalar(scalar), semanticContentCode < 7 else {
            return nil
        }
        return PackedCell.makeUnchecked(contentTag: .codepoint, content: scalar,
                                        styleID: styleID, widthState: widthState,
                                        isProtected: isProtected, payloadCode: payloadCode,
                                        semanticContentCode: semanticContentCode)
    }

    /// Creates a character cell from an attribute identifier that is already
    /// owned by this arena.
    @inline(__always)
    func pack(styleID: UInt16, character: Character,
              widthState: PackedCell.WidthState,
              payloadCode: UInt16 = 0, semanticContentCode: UInt8 = 0,
              isProtected: Bool = false) -> PackedCell?
    {
        let scalars = character.unicodeScalars.map(\.value)
        if scalars.count == 1, let scalar = scalars.first {
            return pack(styleID: styleID, scalar: scalar, widthState: widthState,
                        payloadCode: payloadCode,
                        semanticContentCode: semanticContentCode,
                        isProtected: isProtected)
        }
        guard semanticContentCode < 7 else {
            return nil
        }
        guard let identifier = intern(grapheme: scalars) else {
            let scalar = scalars.first(where: PackedCell.isValidUnicodeScalar) ?? 0xfffd
            return pack(styleID: styleID, scalar: scalar, widthState: widthState,
                        payloadCode: payloadCode,
                        semanticContentCode: semanticContentCode,
                        isProtected: isProtected)
        }
        return PackedCell.makeUnchecked(contentTag: .grapheme, content: identifier,
                                        styleID: styleID, widthState: widthState,
                                        isProtected: isProtected, payloadCode: payloadCode,
                                        semanticContentCode: semanticContentCode)
    }

    @inline(__always)
    func attribute(for identifier: UInt16) -> Attribute {
        attributes[Int(identifier)]
    }

    func intern(grapheme scalars: [UInt32]) -> UInt32? {
        if let identifier = graphemeIdentifiers[scalars] {
            return identifier
        }
        guard !scalars.isEmpty, graphemeCountValue < UInt32(graphemeCapacity) else {
            return nil
        }

        let identifier = graphemeCountValue + 1
        let zeroBased = Int(identifier - 1)
        let blockIndex = zeroBased / Self.graphemeBlockSize
        let slot = zeroBased % Self.graphemeBlockSize
        if graphemeBlocks[blockIndex] == nil {
            let block = UnsafeMutablePointer<[UInt32]?>.allocate(capacity: Self.graphemeBlockSize)
            block.initialize(repeating: nil, count: Self.graphemeBlockSize)
            graphemeBlocks[blockIndex] = block
            allocatedGraphemeBlockCount = max(allocatedGraphemeBlockCount, blockIndex + 1)
        }
        graphemeBlocks[blockIndex]![slot] = scalars
        graphemeCountValue = identifier
        graphemeIdentifiers[scalars] = identifier
        return identifier
    }

    @inline(__always)
    func grapheme(for identifier: UInt32) -> [UInt32]? {
        guard identifier != 0, identifier <= graphemeCountValue else {
            return nil
        }
        let zeroBased = Int(identifier - 1)
        let blockIndex = zeroBased / Self.graphemeBlockSize
        let slot = zeroBased % Self.graphemeBlockSize
        return graphemeBlocks[blockIndex]![slot]
    }

    @inline(__always)
    func logicalCode(for cell: PackedCell) -> Int32 {
        switch cell.contentTag {
        case .codepoint:
            return Int32(cell.content)
        case .grapheme:
            return Int32(grapheme(for: cell.content)?.first ?? 0)
        case .backgroundPalette, .backgroundRGB:
            return 0
        }
    }

    @inline(__always)
    func width(for cell: PackedCell) -> Int8 {
        switch cell.widthState {
        case .narrow: return 1
        case .wide: return 2
        case .spacerTail, .spacerHead: return 0
        }
    }

    @inline(__always)
    func attribute(for cell: PackedCell) -> Attribute {
        switch cell.contentTag {
        case .backgroundPalette:
            return Attribute(fg: .defaultColor,
                             bg: .ansi256(code: UInt8(cell.content)),
                             style: .none)
        case .backgroundRGB:
            return Attribute(
                fg: .defaultColor,
                bg: .trueColor(red: UInt8(cell.content & 0xff),
                               green: UInt8((cell.content >> 8) & 0xff),
                               blue: UInt8((cell.content >> 16) & 0xff)),
                style: .none)
        case .codepoint, .grapheme:
            return attribute(for: cell.styleID)
        }
    }

    @inline(__always)
    func character(for cell: PackedCell) -> Character {
        switch cell.contentTag {
        case .codepoint:
            guard let scalar = Unicode.Scalar(cell.content) else { return " " }
            return Character(scalar)
        case .grapheme:
            guard let values = grapheme(for: cell.content) else { return " " }
            var text = ""
            for value in values {
                guard let scalar = Unicode.Scalar(value) else { return " " }
                text.unicodeScalars.append(scalar)
            }
            return text.first ?? " "
        case .backgroundPalette, .backgroundRGB:
            return "\0"
        }
    }

    func pack(attribute: Attribute, scalar: UInt32, widthState: PackedCell.WidthState,
              payloadCode: UInt16 = 0, semanticContentCode: UInt8 = 0,
              isProtected: Bool = false) -> PackedCell?
    {
        guard PackedCell.isValidUnicodeScalar(scalar) else { return nil }

        let contentTag: PackedCell.ContentTag
        let content: UInt32
        let styleIdentifier: UInt16
        let useBackgroundCell = scalar == 0 &&
            attribute.fg == .defaultColor && attribute.style == .none &&
            attribute.underlineStyle == .none && attribute.underlineColor == nil

        if useBackgroundCell {
            switch attribute.bg {
            case .ansi256(let code):
                contentTag = .backgroundPalette
                content = UInt32(code)
                styleIdentifier = 0
            case .trueColor(let red, let green, let blue):
                contentTag = .backgroundRGB
                content = UInt32(red) | (UInt32(green) << 8) | (UInt32(blue) << 16)
                styleIdentifier = 0
            case .defaultColor, .defaultInvertedColor:
                let style = intern(attribute: attribute) ?? 0
                contentTag = .codepoint
                content = scalar
                styleIdentifier = style
            }
        } else {
            let style = intern(attribute: attribute) ?? 0
            contentTag = .codepoint
            content = scalar
            styleIdentifier = style
        }

        guard semanticContentCode < 7 else { return nil }
        return PackedCell.makeUnchecked(contentTag: contentTag, content: content,
                                        styleID: styleIdentifier, widthState: widthState,
                                        isProtected: isProtected, payloadCode: payloadCode,
                                        semanticContentCode: semanticContentCode)
    }

    func pack(attribute: Attribute, character: Character,
              widthState: PackedCell.WidthState,
              payloadCode: UInt16 = 0, semanticContentCode: UInt8 = 0,
              isProtected: Bool = false) -> PackedCell?
    {
        let scalars = character.unicodeScalars.map(\.value)
        if scalars.count == 1, let scalar = scalars.first {
            return pack(attribute: attribute, scalar: scalar, widthState: widthState,
                        payloadCode: payloadCode,
                        semanticContentCode: semanticContentCode,
                        isProtected: isProtected)
        }
        let style = intern(attribute: attribute) ?? 0
        return pack(styleID: style, character: character, widthState: widthState,
                    payloadCode: payloadCode,
                    semanticContentCode: semanticContentCode,
                    isProtected: isProtected)
    }

    func replacingContent(of cell: PackedCell, with character: Character,
                          widthState: PackedCell.WidthState) -> PackedCell?
    {
        switch cell.contentTag {
        case .codepoint, .grapheme:
            return pack(styleID: cell.styleID, character: character,
                        widthState: widthState, payloadCode: cell.payloadCode,
                        semanticContentCode: cell.semanticContentCode,
                        isProtected: cell.isProtected)
        case .backgroundPalette, .backgroundRGB:
            return pack(attribute: attribute(for: cell), character: character,
                        widthState: widthState, payloadCode: cell.payloadCode,
                        semanticContentCode: cell.semanticContentCode,
                        isProtected: cell.isProtected)
        }
    }

    func pack(_ value: CharData) -> PackedCell? {
        if let grapheme = value.packedGraphemeScalars {
            guard let widthState = PackedCell.WidthState(rawValue: value.packedWidthStateCode) else {
                return nil
            }
            let style = intern(attribute: value.attribute) ?? 0
            if let identifier = intern(grapheme: grapheme) {
                return PackedCell.make(
                    contentTag: .grapheme,
                    content: identifier,
                    styleID: style,
                    widthState: widthState,
                    isProtected: value.isProtected,
                    payloadCode: value.payload.code,
                    semanticContentCode: Self.semanticContentCode(for: value.semanticContent))
            }
            let scalar = grapheme.first(where: PackedCell.isValidUnicodeScalar) ?? 0xfffd
            return pack(styleID: style, scalar: scalar, widthState: widthState,
                        payloadCode: value.payload.code,
                        semanticContentCode: Self.semanticContentCode(for: value.semanticContent),
                        isProtected: value.isProtected)
        }
        guard value.code >= 0,
              let widthState = PackedCell.WidthState(rawValue: value.packedWidthStateCode) else {
            return nil
        }
        return pack(attribute: value.attribute, scalar: UInt32(value.code),
                    widthState: widthState, payloadCode: value.payload.code,
                    semanticContentCode: Self.semanticContentCode(for: value.semanticContent),
                    isProtected: value.isProtected)
    }

    func unpack(_ cell: PackedCell) -> CharData {
        let grapheme = cell.contentTag == .grapheme ? grapheme(for: cell.content) : nil
        return CharData(attribute: attribute(for: cell),
                        code: logicalCode(for: cell),
                        graphemeScalarValues: grapheme,
                        size: width(for: cell),
                        widthStateCode: cell.widthState.rawValue,
                        payloadCode: cell.payloadCode,
                        semanticContent: Self.semanticContent(for: cell.semanticContentCode),
                        isProtected: cell.isProtected)
    }

    @inline(__always)
    static func semanticContentCode(for content: SemanticContent) -> UInt8 {
        switch content {
        case .none: return 0
        case .prompt(.initial): return 1
        case .prompt(.right): return 2
        case .prompt(.continuation): return 3
        case .prompt(.secondary): return 4
        case .input: return 5
        case .output: return 6
        }
    }

    @inline(__always)
    static func semanticContent(for code: UInt8) -> SemanticContent {
        switch code {
        case 1: return .prompt(.initial)
        case 2: return .prompt(.right)
        case 3: return .prompt(.continuation)
        case 4: return .prompt(.secondary)
        case 5: return .input
        case 6: return .output
        default: return .none
        }
    }
}

/// A non-owning decoded view of one packed cell.
///
/// This type keeps internal APIs on the 64-bit representation. The line or
/// snapshot that produced the view must outlive it.
struct PackedCellView {
    let packed: PackedCell
    unowned(unsafe) let arena: CellArena

    @inline(__always) var code: Int32 { arena.logicalCode(for: packed) }
    @inline(__always) var width: Int8 { arena.width(for: packed) }
    @inline(__always) var attribute: Attribute { arena.attribute(for: packed) }
    @inline(__always) var attributeKey: PackedAttributeKey { packed.attributeKey }
    @inline(__always) var semanticContent: SemanticContent {
        CellArena.semanticContent(for: packed.semanticContentCode)
    }
    @inline(__always) var isProtected: Bool { packed.isProtected }
    @inline(__always) var isSimpleRune: Bool { packed.contentTag != .grapheme }
    @inline(__always) var hasPayload: Bool { packed.payloadCode != 0 }

    @inline(__always)
    func getCharacter() -> Character { arena.character(for: packed) }

    @inline(__always)
    func getPayload() -> Any? { TinyAtom.stored(code: packed.payloadCode).target }

    @inline(__always)
    func expanded() -> CharData { arena.unpack(packed) }
}

/// Owns the contiguous 8-byte cells for one terminal row.
final class CellStoragePage {
    private var cells: UnsafeMutableBufferPointer<PackedCell>
    let arena: CellArena

    var count: Int { cells.count }

    init(count: Int, repeating value: CharData = CharData.Null,
         arena: CellArena? = nil, styleCapacity: Int = Int(UInt16.max))
    {
        let selectedArena = arena ?? CellArena(styleCapacity: styleCapacity)
        guard let packed = selectedArena.pack(value) else {
            preconditionFailure("CellStoragePage cannot encode its fill cell")
        }
        self.arena = selectedArena
        cells = .allocate(capacity: count)
        cells.initialize(repeating: packed)
    }

    init(count: Int, repeating packed: PackedCell, arena: CellArena) {
        self.arena = arena
        cells = .allocate(capacity: count)
        cells.initialize(repeating: packed)
    }

    init(copying other: CellStoragePage) {
        arena = other.arena
        cells = .allocate(capacity: other.count)
        if other.count > 0 {
            cells.baseAddress!.initialize(from: other.cells.baseAddress!,
                                          count: other.count)
        }
    }

    deinit {
        cells.deinitialize()
        cells.deallocate()
    }

    @inline(__always)
    func rawCell(at index: Int) -> PackedCell {
        cells[index]
    }

    @inline(__always)
    func view(at index: Int) -> PackedCellView {
        PackedCellView(packed: cells[index], arena: arena)
    }

    @inline(__always)
    func cell(at index: Int) -> CharData {
        arena.unpack(cells[index])
    }

    @inline(__always)
    func logicalCode(at index: Int) -> Int32 {
        arena.logicalCode(for: cells[index])
    }

    @inline(__always)
    func width(at index: Int) -> Int8 {
        arena.width(for: cells[index])
    }

    @inline(__always)
    func attribute(at index: Int) -> Attribute {
        arena.attribute(for: cells[index])
    }

    @inline(__always)
    func character(at index: Int) -> Character {
        arena.character(for: cells[index])
    }

    @inline(__always)
    func isSimpleRune(at index: Int) -> Bool {
        cells[index].contentTag != .grapheme
    }

    @discardableResult
    func replaceCell(at index: Int, with value: CharData) -> Bool {
        guard let packed = arena.pack(value) else { return false }
        cells[index] = packed
        return true
    }

    @inline(__always)
    func setCell(_ value: CharData, at index: Int) {
        precondition(replaceCell(at: index, with: value),
                     "The cell cannot be represented by this storage page")
    }

    @inline(__always)
    func setRawCell(_ value: PackedCell, at index: Int) {
        cells[index] = value
    }

    func packed(_ value: CharData) -> PackedCell {
        guard let packed = arena.pack(value) else {
            preconditionFailure("The cell cannot be represented by this storage page")
        }
        return packed
    }

    @discardableResult
    func fill(with value: CharData) -> Bool {
        guard let packed = arena.pack(value) else { return false }
        fill(with: packed)
        return true
    }

    @inline(__always)
    func fill(with packed: PackedCell) {
        cells.update(repeating: packed)
    }

    func fill(with value: CharData, in range: Range<Int>) {
        fill(with: packed(value), in: range)
    }

    func fill(with packed: PackedCell, in range: Range<Int>) {
        guard !range.isEmpty else { return }
        cells.baseAddress!.advanced(by: range.lowerBound)
            .update(repeating: packed, count: range.count)
    }

    func copyCells(from source: CellStoragePage, sourceStart: Int,
                   destinationStart: Int, count: Int)
    {
        guard count > 0 else { return }
        if source.arena === arena {
            if source !== self {
                cells.baseAddress!.advanced(by: destinationStart).update(
                    from: source.cells.baseAddress!.advanced(by: sourceStart),
                    count: count)
            } else if sourceStart < destinationStart {
                for offset in (0..<count).reversed() {
                    cells[destinationStart + offset] = source.cells[sourceStart + offset]
                }
            } else {
                for offset in 0..<count {
                    cells[destinationStart + offset] = source.cells[sourceStart + offset]
                }
            }
        } else {
            for offset in 0..<count {
                setCell(source.cell(at: sourceStart + offset), at: destinationStart + offset)
            }
        }
    }

    func resized(to newCount: Int, fill value: CharData) -> CellStoragePage {
        resized(to: newCount, fill: packed(value))
    }

    func resized(to newCount: Int, fill packedFill: PackedCell) -> CellStoragePage {
        let result = CellStoragePage(count: newCount, repeating: packedFill, arena: arena)
        result.copyCells(from: self, sourceStart: 0, destinationStart: 0,
                         count: min(count, newCount))
        return result
    }

    func rehomed(to newArena: CellArena) -> CellStoragePage {
        if newArena === arena { return CellStoragePage(copying: self) }
        let result = CellStoragePage(count: count, repeating: CharData.Null, arena: newArena)
        for index in 0..<count {
            result.setCell(cell(at: index), at: index)
        }
        return result
    }

    // Compatibility diagnostics used by storage tests.
    var hasStyles: Bool { cells.contains { $0.styleID != 0 } }
    var hasGraphemes: Bool { cells.contains { $0.contentTag == .grapheme } }
    var hasPayloads: Bool { cells.contains { $0.payloadCode != 0 } }
    var styleCount: Int { Set(cells.lazy.map(\.styleID).filter { $0 != 0 }).count }
    var graphemeCount: Int { cells.lazy.filter { $0.contentTag == .grapheme }.count }
    var payloadCount: Int { cells.lazy.filter { $0.payloadCode != 0 }.count }

    func styleReferenceCount(for identifier: UInt16) -> Int {
        cells.lazy.filter { $0.styleID == identifier }.count
    }

    func compactPresenceFlags() {}

    func isConsistent(at index: Int) -> Bool {
        let cell = cells[index]
        guard cell.hasValidEncoding else { return false }
        if cell.contentTag == .grapheme && arena.grapheme(for: cell.content) == nil {
            return false
        }
        return true
    }
}
