import Foundation

/// One capability of a terminfo source entry.
struct TerminfoCapability {
    enum Value {
        /// A capability that is only present or absent.
        case boolean
        /// An unsigned decimal capability, written as `name#value`.
        case numeric(UInt32)
        /// A string capability, written as `name=value`.
        case string(String)
    }

    let name: String
    let value: Value
}

enum TerminfoSourceError: Error, CustomStringConvertible {
    case unreadableFile(String)
    case missingEntryName(String)
    case malformedLine(String)
    case invalidName(String)
    case invalidNumber(String)
    case canceledCapability(String)
    case duplicateCapability(String)

    var description: String {
        switch self {
        case .unreadableFile(let path):
            return "cannot read the terminfo source at \(path)"
        case .missingEntryName(let path):
            return "\(path) has no terminfo entry name line"
        case .malformedLine(let line):
            return "terminfo line does not end with a comma: \(line)"
        case .invalidName(let name):
            return "invalid terminfo capability name: \(name)"
        case .invalidNumber(let text):
            return "invalid terminfo numeric value: \(text)"
        case .canceledCapability(let name):
            return "canceled terminfo capability is not supported: \(name)"
        case .duplicateCapability(let name):
            return "duplicate terminfo capability: \(name)"
        }
    }
}

/// Reads the checked-in terminfo source entry.
///
/// This parser accepts the subset of terminfo(5) source syntax that the
/// SwiftTerm entry uses: a comment line, one entry-name line, and one
/// tab-indented capability for each following line.
enum TerminfoSource {
    static func capabilities(atPath path: String) throws -> [TerminfoCapability] {
        guard let text = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else {
            throw TerminfoSourceError.unreadableFile(path)
        }

        var capabilities: [TerminfoCapability] = []
        var names: Set<String> = []
        var sawEntryName = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            // The entry-name line is the only one that starts at column zero.
            if !rawLine.hasPrefix(" ") && !rawLine.hasPrefix("\t") {
                sawEntryName = true
                continue
            }
            guard line.hasSuffix(",") else {
                throw TerminfoSourceError.malformedLine(line)
            }

            let capability = try parse(body: String(line.dropLast()))
            guard names.insert(capability.name).inserted else {
                throw TerminfoSourceError.duplicateCapability(capability.name)
            }
            capabilities.append(capability)
        }

        guard sawEntryName else {
            throw TerminfoSourceError.missingEntryName(path)
        }
        return capabilities
    }

    private static func parse(body: String) throws -> TerminfoCapability {
        // A string value can hold a `#`, so the `=` form is recognized first.
        if let separator = body.firstIndex(of: "=") {
            let name = String(body[..<separator])
            try validate(name: name)
            return TerminfoCapability(name: name,
                                      value: .string(String(body[body.index(after: separator)...])))
        }
        if let separator = body.firstIndex(of: "#") {
            let name = String(body[..<separator])
            try validate(name: name)
            let text = String(body[body.index(after: separator)...])
            guard let number = UInt32(text) else {
                throw TerminfoSourceError.invalidNumber(text)
            }
            return TerminfoCapability(name: name, value: .numeric(number))
        }
        // A trailing `@` cancels a capability. The SwiftTerm entry has none, and
        // XTGETTCAP has no way to report one.
        if body.hasSuffix("@") {
            throw TerminfoSourceError.canceledCapability(String(body.dropLast()))
        }
        try validate(name: body)
        return TerminfoCapability(name: body, value: .boolean)
    }

    private static func validate(name: String) throws {
        guard !name.isEmpty else {
            throw TerminfoSourceError.invalidName(name)
        }
        for byte in name.utf8 {
            let isValid = (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || byte == UInt8(ascii: "_")
            guard isValid else {
                throw TerminfoSourceError.invalidName(name)
            }
        }
    }
}
