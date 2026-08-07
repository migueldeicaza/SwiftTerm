import AppKit
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import SwiftTerm
import WebKit

struct VisibleRowManifest: Codable {
    var row: Int
    var text: String
    var isWrapped: Bool
    var bidiState: String
}

struct HarnessManifest: Codable {
    var schemaVersion = 1
    var runID: String
    var scenario: String
    var step: String
    var renderer: String
    var gitRevision: String
    var capturedAt: String
    var operatingSystem: String
    var backingScale: Double
    var fontName: String
    var fontSize: Double
    var cols: Int
    var rows: Int
    var cursorColumn: Int
    var cursorRow: Int
    var viewportRow: Int
    var scrollPosition: Double
    var currentBidiState: String
    var arrowKeySwap: Bool
    var hostPolicy: String
    var customBlockGlyphs: Bool
    var selection: String?
    var outgoingBytesBase64: String
    var logicalBufferSHA256: String
    var visibleRows: [VisibleRowManifest]
    var assertions: [AssertionResult]
    var timingsMilliseconds: [String: Double]
    var imagePath: String
}

struct CaptureResult {
    var imageURL: URL
    var manifestURL: URL
    var logicalBufferURL: URL
    var manifest: HarnessManifest
}

enum ArtifactCapture {
    static func captureWindow(
        _ window: NSWindow,
        terminalView: TerminalView,
        webView: WKWebView,
        referenceFallback: NSImage
    ) throws -> Data {
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
        CATransaction.flush()

        let windowID = CGWindowID(window.windowNumber)
        // CGWindowListCreateImage can omit CAMetalLayer contents and return a
        // plausible window image with a black terminal pane. The macOS window
        // capture service includes the presented Metal drawable.
        if terminalView.isUsingMetalRenderer,
           let data = capturePresentedWindow(windowID: windowID) {
            return data
        }

        if !terminalView.isUsingMetalRenderer,
           let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution]) {
            let representation = NSBitmapImageRep(cgImage: image)
            if !isEffectivelyBlack(representation),
               let data = representation.representation(using: .png, properties: [:]), !data.isEmpty {
                return data
            }
        }

        guard let contentView = window.contentView,
              let baseRepresentation = bitmapRepresentation(of: contentView) else {
            throw HarnessError.captureUnavailable("Could not create a window image")
        }

        guard let terminalRepresentation = bitmapRepresentation(of: terminalView),
              !isEffectivelyBlack(terminalRepresentation) else {
            let detail = terminalView.isUsingMetalRenderer
                ? "Metal capture needs Screen Recording access when the WindowServer image is unavailable"
                : "Could not draw the terminal view into an offscreen image"
            throw HarnessError.captureUnavailable(detail)
        }
        let webImage = webSnapshot(webView) ?? referenceFallback

        let scale = max(1, window.backingScaleFactor)
        guard let composite = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(contentView.bounds.width * scale)),
            pixelsHigh: Int(ceil(contentView.bounds.height * scale)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { throw HarnessError.captureUnavailable("Could not allocate the composite image") }
        composite.size = contentView.bounds.size
        guard let context = NSGraphicsContext(bitmapImageRep: composite) else {
            throw HarnessError.captureUnavailable("Could not create the composite graphics context")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        baseRepresentation.draw(in: contentView.bounds)
        terminalRepresentation.draw(in: terminalView.convert(terminalView.bounds, to: contentView))
        webImage.draw(in: webView.convert(webView.bounds, to: contentView))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = composite.representation(using: .png, properties: [:]), !data.isEmpty else {
            throw HarnessError.captureUnavailable("The fallback view image is empty")
        }
        return data
    }

    private static func capturePresentedWindow(windowID: CGWindowID) -> Data? {
        guard let socketPath = ProcessInfo.processInfo.environment["SWIFTTERM_CAPTURE_SOCKET"],
              !socketPath.isEmpty else {
            return nil
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftterm-bidi-metal-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: output) }

        guard requestWindowCapture(socketPath: socketPath, windowID: windowID,
                                   output: output.path),
              let data = try? Data(contentsOf: output), !data.isEmpty,
              let representation = NSBitmapImageRep(data: data),
              !isEffectivelyBlack(representation) else {
            return nil
        }
        return data
    }

    private static func requestWindowCapture(socketPath: String, windowID: CGWindowID,
                                             output: String) -> Bool {
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            return false
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: pathBytes)
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, length)
            }
        }
        guard connected == 0,
              JSONSerialization.isValidJSONObject(["windowID": windowID, "output": output]),
              var request = try? JSONSerialization.data(
                withJSONObject: ["windowID": windowID, "output": output]) else {
            return false
        }
        request.append(0x0a)
        let wroteRequest = request.withUnsafeBytes { bytes -> Bool in
            guard var pointer = bytes.baseAddress else { return false }
            var remaining = bytes.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                guard written > 0 else { return false }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
            return true
        }
        guard wroteRequest else { return false }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while response.count <= 65_536, response.last != 0x0a {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count > 0 else { return false }
            response.append(contentsOf: buffer[0..<count])
        }
        guard let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            return false
        }
        return object["ok"] as? Bool == true
    }

    private static func bitmapRepresentation(of view: NSView) -> NSBitmapImageRep? {
        guard !view.bounds.isEmpty,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: representation)
        return representation
    }

    private static func webSnapshot(_ webView: WKWebView) -> NSImage? {
        let configuration = WKPDFConfiguration()
        configuration.rect = webView.bounds
        var pdfResult: Data?
        var pdfComplete = false
        webView.createPDF(configuration: configuration) { result in
            pdfResult = try? result.get()
            pdfComplete = true
        }
        var deadline = Date(timeIntervalSinceNow: 2)
        while !pdfComplete, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        if let pdfResult, let image = NSImage(data: pdfResult), imageHasVisibleContent(image, size: webView.bounds.size) {
            return image
        }

        var result: NSImage?
        var complete = false
        webView.takeSnapshot(with: nil) { image, _ in
            result = image
            complete = true
        }
        deadline = Date(timeIntervalSinceNow: 2)
        while !complete, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        if let result, imageHasVisibleContent(result, size: webView.bounds.size) {
            return result
        }
        return nil
    }

    private static func imageHasVisibleContent(_ image: NSImage, size: NSSize) -> Bool {
        guard size.width > 0, size.height > 0,
              let representation = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: max(1, Int(size.width)),
                pixelsHigh: max(1, Int(size.height)),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ), let context = NSGraphicsContext(bitmapImageRep: representation) else { return false }
        representation.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: size))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return !isEffectivelyBlack(representation)
    }

    private static func isEffectivelyBlack(_ representation: NSBitmapImageRep) -> Bool {
        guard representation.pixelsWide > 0, representation.pixelsHigh > 0 else { return true }
        var samples = 0
        var visibleSamples = 0
        let horizontalStep = max(1, representation.pixelsWide / 40)
        let verticalStep = max(1, representation.pixelsHigh / 24)
        for y in stride(from: 0, to: representation.pixelsHigh, by: verticalStep) {
            for x in stride(from: 0, to: representation.pixelsWide, by: horizontalStep) {
                samples += 1
                guard let color = representation.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if max(color.redComponent, color.greenComponent, color.blueComponent) > 0.04 {
                    visibleSamples += 1
                }
            }
        }
        return samples == 0 || Double(visibleSamples) / Double(samples) < 0.005
    }

    static func write(
        pngData: Data,
        logicalText: String,
        manifest: HarnessManifest,
        root: URL
    ) throws -> CaptureResult {
        let directory = root
            .appendingPathComponent(manifest.runID.safeArtifactComponent, isDirectory: true)
            .appendingPathComponent(manifest.scenario.safeArtifactComponent, isDirectory: true)
            .appendingPathComponent(manifest.step.safeArtifactComponent, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let base = manifest.renderer.safeArtifactComponent
            let imageURL = directory.appendingPathComponent("\(base).png")
            let manifestURL = directory.appendingPathComponent("\(base).json")
            let bufferURL = directory.appendingPathComponent("logical-buffer.txt")
            try pngData.write(to: imageURL, options: .atomic)
            try logicalText.write(to: bufferURL, atomically: true, encoding: .utf8)
            var finalManifest = manifest
            finalManifest.imagePath = imageURL.path
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(finalManifest).write(to: manifestURL, options: .atomic)
            return CaptureResult(
                imageURL: imageURL,
                manifestURL: manifestURL,
                logicalBufferURL: bufferURL,
                manifest: finalManifest
            )
        } catch let error as HarnessError {
            throw error
        } catch {
            throw HarnessError.io("Could not write capture artifacts: \(error.localizedDescription)")
        }
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

func bidiStateName(_ state: BidiPresentationState) -> String {
    switch state.presentationMode {
    case .implicitLeftToRight: return "implicitLeftToRight"
    case .implicitRightToLeft: return "implicitRightToLeft"
    case .implicitAutoLeftToRight: return "implicitAutoLeftToRight"
    case .implicitAutoRightToLeft: return "implicitAutoRightToLeft"
    case .explicitLeftToRight: return "explicitLeftToRight"
    case .explicitRightToLeft: return "explicitRightToLeft"
    }
}
