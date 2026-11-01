/*
 * Adapted from Ghostty's untrusted URL policy and alert.
 * https://github.com/ghostty-org/ghostty/commit/77537c8065f3055d214144caab7d137543a6e133
 *
 * MIT License
 *
 * Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */
#if os(macOS) && !SWIFTTERM_EMBEDDED
import Foundation
import UniformTypeIdentifiers

/// Checks a link from terminal output before the system opens it.
struct UntrustedTerminalLink: Equatable {
    enum DenialReason: Equatable {
        case malformedURL
        case unsafeCharacters
        case invalidWebURL
        case inaccessibleFile
        case unsafeFile

        var message: String {
            switch self {
            case .malformedURL:
                return "The target is not an absolute URL with a scheme."
            case .unsafeCharacters:
                return "The target contains invisible characters or line breaks."
            case .invalidWebURL:
                return "The web target does not have a valid host."
            case .inaccessibleFile:
                return "The local target does not exist or is not a regular file or directory."
            case .unsafeFile:
                return "This local target can run code."
            }
        }
    }

    enum Decision: Equatable {
        case allow(URL)
        case confirm(URL)
        case deny(DenialReason)
    }

    let string: String

    init(_ string: String) {
        self.string = string
    }

    var decision: Decision {
        guard !string.isEmpty else { return .deny(.malformedURL) }
        // Check the source first. URL conversion can encode unsafe characters.
        guard !Self.containsUnsafeCharacters(string) else {
            return .deny(.unsafeCharacters)
        }
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              !scheme.isEmpty else {
            return .deny(.malformedURL)
        }

        switch scheme {
        case "http", "https":
            guard let host = url.host, !host.isEmpty else {
                return .deny(.invalidWebURL)
            }
            return .allow(url)
        case "mailto":
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  !components.path.isEmpty else {
                return .deny(.malformedURL)
            }
            return .allow(url)
        case "file":
            return fileDecision(for: url)
        default:
            // A custom scheme can start an application through Launch Services.
            return .confirm(url)
        }
    }

    static func containsUnsafeCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains(where: isUnsafeCharacter)
    }

    /// Shows the effective target on one line.
    var displayString: String {
        let normalized: String
        if let url = URL(string: string), url.scheme != nil {
            // Use the same path for the preview and the file check.
            normalized = url.isFileURL
                ? url.standardizedFileURL.resolvingSymlinksInPath().path
                : string
        } else {
            normalized = URL(fileURLWithPath: string).standardizedFileURL.path
        }

        // Escape after path conversion, which can decode unsafe characters.
        var result = String()
        result.reserveCapacity(normalized.count)
        for scalar in normalized.unicodeScalars {
            if Self.isUnsafeCharacter(scalar) {
                result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

private extension UntrustedTerminalLink {
    func fileDecision(for url: URL) -> Decision {
        guard url.isFileURL, url.query == nil, url.fragment == nil else {
            return .deny(.malformedURL)
        }
        if let host = url.host,
           !host.isEmpty,
           host.caseInsensitiveCompare("localhost") != .orderedSame {
            return .deny(.malformedURL)
        }

        // Check the actual file. A link can hide an executable target.
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let values: URLResourceValues
        do {
            values = try canonicalURL.resourceValues(forKeys: [
                .contentTypeKey, .isDirectoryKey, .isExecutableKey, .isRegularFileKey,
            ])
        } catch {
            return .deny(.inaccessibleFile)
        }
        guard values.isDirectory == true || values.isRegularFile == true else {
            return .deny(.inaccessibleFile)
        }
        guard !Self.isUnsafeFile(canonicalURL, resourceValues: values) else {
            return .deny(.unsafeFile)
        }
        return .allow(canonicalURL)
    }

    static func isUnsafeFile(_ url: URL, resourceValues: URLResourceValues) -> Bool {
        // Launch Services uses the extension to select an application.
        if unsafePathExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }
        if let contentType = resourceValues.contentType,
           unsafeContentTypes.contains(where: { contentType.conforms(to: $0) }) {
            return true
        }
        return resourceValues.isDirectory != true && resourceValues.isExecutable == true
    }

    static func isUnsafeCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F:
            return true
        case 0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return true
        case 0x2028...0x2029, 0x2060, 0xFEFF:
            return true
        default:
            return false
        }
    }

    static let unsafePathExtensions: Set<String> = [
        "action", "app", "applescript", "class", "command", "desktop",
        "inetloc", "jar", "mobileconfig", "mpkg", "pkg", "scpt", "terminal",
        "tool", "url", "webloc", "workflow",
    ]

    static let unsafeContentTypes: [UTType] = [.application, .executable, .script]
}
#endif
