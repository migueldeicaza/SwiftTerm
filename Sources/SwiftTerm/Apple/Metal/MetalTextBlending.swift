#if !SWIFTTERM_EMBEDDED
#if os(macOS) || os(iOS) || os(visionOS)
/// Controls how monochrome glyph coverage is blended by the Metal renderer.
///
/// You can change this at any time via ``TerminalView/metalTextBlending``.
public enum MetalTextBlending: Sendable, Hashable {
    /// Blends glyph coverage directly in sRGB space, matching native macOS
    /// CoreGraphics compositing on Retina displays.
    case native

    /// Applies perceptual gamma-corrected coverage blending so antialiased
    /// strokes keep consistent optical weight across light and dark themes.
    case linearCorrected
}
#endif

#endif // !SWIFTTERM_EMBEDDED
