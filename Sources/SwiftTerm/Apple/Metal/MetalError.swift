#if os(macOS) || os(iOS) || os(visionOS)
import Foundation

public enum MetalError: Error, CustomStringConvertible {
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
        }
    }
}
#endif
