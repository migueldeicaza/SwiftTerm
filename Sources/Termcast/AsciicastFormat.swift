import Foundation

struct AsciicastHeader: Codable {
    let version: Int
    let width: Int
    let height: Int
    let timestamp: TimeInterval
    let command: String?
    let title: String?
    let env: [String: String]?
}

enum AsciicastEventType: String, Codable {
    case output = "o"
    case input = "i"
    case resize = "r"
    case marker = "m"
}

struct AsciicastEvent: Codable {
    let time: TimeInterval
    let eventType: AsciicastEventType
    let eventData: String

    init(time: TimeInterval, eventType: AsciicastEventType, eventData: String) {
        self.time = time
        self.eventType = eventType
        self.eventData = eventData
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        self.time = try container.decode(TimeInterval.self)
        self.eventType = try container.decode(AsciicastEventType.self)
        self.eventData = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(time)
        try container.encode(eventType)
        try container.encode(eventData)
    }
}