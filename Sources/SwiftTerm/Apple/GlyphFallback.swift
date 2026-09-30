//
//  GlyphFallback.swift
//
// Host-supplied glyph fallback for symbol codepoints (for example Nerd Font
// icons) that the selected terminal font does not contain. The library owns
// the coverage check against the requested face and the placement math; the
// host owns the fallback font asset and the per-codepoint placement data.
//
#if !SWIFTTERM_EMBEDDED
#if os(macOS) || os(iOS) || os(visionOS)
import Foundation
import CoreGraphics
import CoreText

/// Padding, in fractions of one cell, that a placement policy reserves around
/// a fallback glyph inside its slot.
public struct TerminalGlyphPadding: Hashable, Sendable {
    public var top: CGFloat
    public var left: CGFloat
    public var bottom: CGFloat
    public var right: CGFloat

    public init (top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public static let zero = TerminalGlyphPadding()
}

/// How a fallback glyph is placed within its cell slot. The host supplies one
/// policy per candidate scalar; the renderers apply it identically on the
/// CoreGraphics and Metal paths.
public struct TerminalGlyphPlacementPolicy: Hashable, Sendable {
    public enum Placement: Hashable, Sendable {
        /// Preserve the aspect ratio, fit the glyph inside the allowed slot and
        /// center it. A one-column icon is additionally limited to the primary
        /// font's icon height. Never upscales past the glyph's natural size.
        case icon
        /// Fill the intended cell width, scaling uniformly in either
        /// direction, bounded only by the cell height. The icon-height limit
        /// does not apply.
        case cover
        /// Fill the slot exactly, scaling each axis independently
        /// (Powerline-style separators). The icon-height limit does not apply.
        case stretch
        /// Use the policy's `maximumCellWidth` and `padding` verbatim.
        case explicitWidth
        /// Apply `relativeBounds` (group-relative, unit space) before fitting,
        /// so glyphs that belong to one upstream group do not shift vertically
        /// relative to each other.
        case grouped
    }

    public var placement: Placement
    /// Upper bound, in cells, on the slot the glyph may occupy. `nil` means
    /// the cluster's own column width.
    public var maximumCellWidth: Int?
    /// Group-relative bounds in unit space, used by `.grouped`.
    public var relativeBounds: CGRect?
    public var padding: TerminalGlyphPadding

    public init (placement: Placement, maximumCellWidth: Int? = nil,
                 relativeBounds: CGRect? = nil,
                 padding: TerminalGlyphPadding = .zero) {
        self.placement = placement
        self.maximumCellWidth = maximumCellWidth
        self.relativeBounds = relativeBounds
        self.padding = padding
    }
}

/// A host-supplied source of fallback glyphs for known symbol codepoints.
///
/// Set an implementation on ``TerminalView/glyphFallbackProvider`` to enable
/// the feature; the default of `nil` leaves rendering unchanged. The provider
/// is consulted only for scalars it claims via ``placementPolicy(for:)`` and
/// only after the requested terminal face was found to lack the glyph, so a
/// user-selected patched font always keeps priority.
///
/// Implementations must be thread-safe: the render pipeline may call them from
/// a dedicated render thread. ``fallbackFont(forPointSize:)`` must return the
/// same `CTFont` instance for repeated calls at one size — renderer caches key
/// on font identity, and a fresh instance per call would defeat them and grow
/// them without bound.
public protocol TerminalGlyphFallbackProvider: AnyObject, Sendable {
    /// The placement policy for `scalar`, or `nil` when the scalar is not a
    /// fallback candidate. Candidacy must be an exact set: claiming a broad
    /// private-use range would replace an application's unrelated glyphs.
    func placementPolicy (for scalar: Unicode.Scalar) -> TerminalGlyphPlacementPolicy?

    /// The fallback face at `size` points, or `nil` when it is unavailable
    /// (for example, when font registration failed). Memoize per size and
    /// return a stable instance.
    func fallbackFont (forPointSize size: CGFloat) -> CTFont?

    /// Bump this when the provider's data or font changes. It is hashed into
    /// the render cache identities together with the provider's object
    /// identity, so stale glyphs cannot survive a change.
    var generation: UInt64 { get }
}

extension TerminalGlyphFallbackProvider {
    /// A value that changes whenever the provider instance or its data
    /// changes; 0 is reserved for "no provider".
    var cacheIdentity: UInt64 {
        UInt64(bitPattern: Int64(ObjectIdentifier(self).hashValue)) &+ generation
    }
}

/// Cache-free primitives for resolving a host glyph fallback. The text
/// builder wraps these with its per-renderer caches; the caret path, which
/// resolves one cell per snapshot refresh, calls them directly.
enum GlyphFallbackResolver {
    /// The scalar the provider is asked about: the cluster's only scalar, or
    /// its first when the only other scalar is a variation selector. Any
    /// other multi-scalar cluster is never a fallback candidate.
    static func baseScalar (of character: Character) -> Unicode.Scalar? {
        var iterator = character.unicodeScalars.makeIterator()
        guard let first = iterator.next() else { return nil }
        guard let second = iterator.next() else { return first }
        guard iterator.next() == nil, UnicodeUtil.isVariationSelector(second.value) else {
            return nil
        }
        return first
    }

    /// Whether `font` itself contains a glyph for `scalar`. A direct cmap
    /// query: unlike `CTFontCreateForString` it performs no fallback, so a
    /// missing glyph is reported as missing rather than papered over by a
    /// platform-dependent cascade.
    static func fontHasGlyph (_ font: TTFont, scalar: Unicode.Scalar) -> Bool {
        var units = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        return CTFontGetGlyphsForCharacters(font as CTFont, &units, &glyphs, units.count)
    }

    /// Uncached resolution for one cell: the fallback font and policy when
    /// `character` is a claimed candidate that `styleFont` cannot draw, nil
    /// otherwise.
    static func selection (for character: Character, styleFont: TTFont,
                           context: SnapshotRenderContext)
        -> (font: TTFont, policy: TerminalGlyphPlacementPolicy)?
    {
        guard let provider = context.glyphFallbackProvider,
              let scalar = baseScalar(of: character),
              let policy = provider.placementPolicy(for: scalar),
              !fontHasGlyph(styleFont, scalar: scalar),
              let fallback = provider.fallbackFont(forPointSize: context.fonts.normal.pointSize)
        else {
            return nil
        }
        return (fallback as TTFont, policy)
    }
}
#endif

#endif // !SWIFTTERM_EMBEDDED
