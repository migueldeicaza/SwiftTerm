import Foundation
import Testing

/// Reads the terminfo entry that generates the reply table.
enum TerminfoFixture {
    static func fixtureURL() throws -> URL {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let repository = sourceFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = repository.appendingPathComponent("swifterm-terminfo")
        return try #require(FileManager.default.fileExists(atPath: fixture.path) ? fixture : nil)
    }

    static func capabilityNames() throws -> [String] {
        let text = try String(contentsOf: fixtureURL(), encoding: .utf8)
        var names: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            // Only indented lines contain capabilities.
            guard rawLine.hasPrefix(" ") || rawLine.hasPrefix("\t"), line.hasSuffix(",") else {
                continue
            }
            let body = String(line.dropLast())
            if let separator = body.firstIndex(of: "=") {
                names.append(String(body[..<separator]))
            } else if let separator = body.firstIndex(of: "#") {
                names.append(String(body[..<separator]))
            } else {
                names.append(body)
            }
        }
        return names
    }

    static func hexEncoded(_ text: String) -> String {
        text.utf8.map { String(format: "%02X", $0) }.joined()
    }
}
