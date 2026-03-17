#if os(macOS) || os(iOS) || os(visionOS)
/// Controls how the Metal renderer builds and caches GPU buffers each frame.
///
/// The buffering mode affects the trade-off between memory usage and redraw
/// performance. You can change this at any time via
/// ``TerminalView/metalBufferingMode``.
public enum MetalBufferingMode {
    /// Each terminal row's vertex data is cached independently and reused across
    /// frames. Only rows marked dirty are rebuilt, making this the best choice
    /// for typical interactive use where only a few rows change per frame.
    case perRowPersistent

    /// All visible rows are aggregated into a single buffer every frame.
    /// This avoids per-row bookkeeping and may be preferable for workloads
    /// that redraw most of the screen each frame (for example, full-screen
    /// TUI applications).
    case perFrameAggregated
}
#endif
