import Foundation

enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var foundationValue: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .object(let value): return value.mapValues(\.foundationValue)
        case .array(let value): return value.map(\.foundationValue)
        case .null: return NSNull()
        }
    }
}

struct HarnessCommand: Codable, Equatable {
    var command: String
    var arguments: [String: JSONValue] = [:]
}

struct ScenarioReferenceLine: Codable, Equatable {
    var text: String
    /// auto, ltr, or rtl.
    var direction: String
    /// implicit runs the browser BiDi algorithm. visual preserves exact cells.
    var mode: String
    /// auto, left, or right.
    var alignment: String
}

struct ScenarioReference: Codable, Equatable {
    var text: String?
    var fixture: String?
    var direction: String = "auto"
    var lines: [ScenarioReferenceLine]?
    var initialLineCount: Int?
}

struct ScenarioInitialState: Codable, Equatable {
    var cols: Int = 80
    var rows: Int = 24
    var scrollback: Int = 500
    var maximumBidiParagraphRows: Int = 500
    var renderer: String = "coreGraphics"
    var hostPolicy: String = "respectTerminal"
    var customBlockGlyphs: Bool = true
    var fontName: String = "Menlo"
    var fontSize: Double = 14
}

struct ScenarioAssertion: Codable, Equatable {
    var kind: String
    var arguments: [String: JSONValue] = [:]
}

struct ScenarioStep: Codable, Equatable {
    var id: String
    var title: String
    var actions: [HarnessCommand]
    var capture: Bool = false
    var assertions: [ScenarioAssertion] = []
    var reference: ScenarioReference? = nil
    var referenceLineCount: Int? = nil
}

struct HarnessScenario: Codable, Equatable {
    var schemaVersion: Int
    var id: String
    var title: String
    var purpose: String
    var initial: ScenarioInitialState
    var reference: ScenarioReference
    var setup: [HarnessCommand] = []
    var steps: [ScenarioStep]

    func validate() throws {
        guard schemaVersion == 1 else {
            throw HarnessError.invalidScenario("Unsupported schema version: \(schemaVersion)")
        }
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            throw HarnessError.invalidScenario("Invalid scenario identifier: \(id)")
        }
        guard initial.cols > 0, initial.rows > 0, initial.scrollback >= 0 else {
            throw HarnessError.invalidScenario("Invalid initial terminal dimensions or scrollback")
        }
        guard initial.maximumBidiParagraphRows > 0 else {
            throw HarnessError.invalidScenario("maximumBidiParagraphRows must be positive")
        }
        let identifiers = steps.map(\.id)
        guard Set(identifiers).count == identifiers.count else {
            throw HarnessError.invalidScenario("Step identifiers must be unique")
        }
    }
}

struct AssertionResult: Codable, Equatable {
    var kind: String
    var passed: Bool
    var message: String
}

enum HarnessError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case invalidCommand(String)
    case invalidScenario(String)
    case notFound(String)
    case captureUnavailable(String)
    case io(String)

    var code: String {
        switch self {
        case .invalidArgument: return "invalidArgument"
        case .invalidCommand: return "invalidCommand"
        case .invalidScenario: return "invalidScenario"
        case .notFound: return "notFound"
        case .captureUnavailable: return "captureUnavailable"
        case .io: return "ioError"
        }
    }

    var description: String {
        switch self {
        case .invalidArgument(let message), .invalidCommand(let message),
             .invalidScenario(let message), .notFound(let message),
             .captureUnavailable(let message), .io(let message):
            return message
        }
    }
}

struct JSONLineFramer {
    private(set) var pending = Data()
    let maximumMessageBytes: Int

    init(maximumMessageBytes: Int = 1_048_576) {
        self.maximumMessageBytes = maximumMessageBytes
    }

    mutating func append(_ data: Data) throws -> [Data] {
        pending.append(data)
        guard pending.count <= maximumMessageBytes else {
            throw HarnessError.invalidArgument("The JSON message is larger than \(maximumMessageBytes) bytes")
        }
        var messages: [Data] = []
        while let newline = pending.firstIndex(of: 0x0a) {
            let message = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            if !message.isEmpty {
                messages.append(message)
            }
        }
        return messages
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) -> String? {
        guard case .string(let value) = self[key] else { return nil }
        return value
    }

    func int(_ key: String) -> Int? {
        guard case .number(let value) = self[key], value.rounded() == value else { return nil }
        return Int(value)
    }

    func double(_ key: String) -> Double? {
        guard case .number(let value) = self[key] else { return nil }
        return value
    }

    func bool(_ key: String) -> Bool? {
        guard case .bool(let value) = self[key] else { return nil }
        return value
    }

    func object(_ key: String) -> [String: JSONValue]? {
        guard case .object(let value) = self[key] else { return nil }
        return value
    }
}

extension String {
    var safeArtifactComponent: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let result = unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let normalized = String(result).replacingOccurrences(of: "--", with: "-")
        return String(normalized.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
