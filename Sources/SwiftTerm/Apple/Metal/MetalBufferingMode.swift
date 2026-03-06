#if os(macOS) || os(iOS) || os(visionOS)
public enum MetalBufferingMode {
    case perRowPersistent
    case perFrameAggregated
}
#endif
