#if os(macOS) || os(iOS) || os(visionOS)
import Foundation

/// Initialization, configuration, and runtime failures of the Metal renderer.
public enum MetalError: Error, CustomStringConvertible, Sendable {
    case metalKitUnavailable
    case deviceUnavailable
    case commandQueueUnavailable
    case atlasUnavailable
    case shaderLibraryMissing
    case shaderLibraryLoadFailed(String)
    case shaderFunctionMissing(String)
    case shaderSourceMissing(String)
    case shaderCompilationFailed(String)
    case pipelineCreationFailed(String)
    case samplerUnavailable
    case rendererBusy
    case commandBufferUnavailable
    case renderEncoderUnavailable
    case commandFailed(String)
    case commandTimedOut
    case inFlightLimitReached

    public var description: String {
        switch self {
        case .metalKitUnavailable:
            return "MetalKit is unavailable."
        case .deviceUnavailable:
            return "No Metal device is available."
        case .commandQueueUnavailable:
            return "Failed to create Metal command queue."
        case .atlasUnavailable:
            return "Failed to create the glyph atlas."
        case .shaderLibraryMissing:
            return "Failed to locate a Metal library in bundle resources."
        case .shaderLibraryLoadFailed(let reason):
            return "Failed to load Metal library: \(reason)"
        case .shaderFunctionMissing(let name):
            return "Metal library missing required function: \(name)"
        case .shaderSourceMissing(let name):
            return "Failed to load Metal shader source: \(name)"
        case .shaderCompilationFailed(let reason):
            return "Failed to compile Metal shader source: \(reason)"
        case .pipelineCreationFailed(let name):
            return "Failed to create Metal pipeline: \(name)"
        case .samplerUnavailable:
            return "Failed to create Metal sampler state."
        case .rendererBusy:
            return "The Metal renderer did not become idle before teardown."
        case .commandBufferUnavailable:
            return "Failed to create a Metal command buffer."
        case .renderEncoderUnavailable:
            return "Failed to create a Metal render encoder."
        case .commandFailed(let reason):
            return "Metal command failed: \(reason)"
        case .commandTimedOut:
            return "A submitted Metal command did not finish within five seconds."
        case .inFlightLimitReached:
            return "Metal rendering cannot resume until an outstanding frame completes."
        }
    }
}
#endif
