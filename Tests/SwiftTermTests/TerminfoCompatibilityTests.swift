import Foundation
import Testing

@testable import SwiftTerm

struct TerminfoCompatibilityTests {
    private func fixtureURL() throws -> URL {
        try #require(
            Bundle.module.url(forResource: "xterm-ghostty", withExtension: "infocmp")
                ?? Bundle.module.url(forResource: "xterm-ghostty", withExtension: "infocmp",
                                     subdirectory: "Fixtures")
        )
    }

    private func swiftTermFixtureURL() throws -> URL {
        try TerminfoFixture.fixtureURL()
    }

    private func fixtureCapabilities() throws -> (names: [String], values: [String: String]) {
        let text = try String(contentsOf: fixtureURL(), encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let names = String(lines[0].dropLast()).split(separator: "|").map(String.init)
        var values: [String: String] = [:]
        for line in lines.dropFirst() {
            let capability = String(line.dropLast())
            if let separator = capability.firstIndex(of: "=") {
                values[String(capability[..<separator])] = String(capability[capability.index(after: separator)...])
            } else if let separator = capability.firstIndex(of: "#") {
                values[String(capability[..<separator])] = String(capability[capability.index(after: separator)...])
            } else {
                values[capability] = ""
            }
        }
        return (names, values)
    }

    @Test func swiftTermEntryMatchesTheFixedGhosttyCapabilities() throws {
        let swiftTermText = try String(contentsOf: swiftTermFixtureURL(), encoding: .utf8)
        let fixtureText = try String(contentsOf: fixtureURL(), encoding: .utf8)
        let swiftTermLines = swiftTermText.split(whereSeparator: \.isNewline)
        let fixtureLines = fixtureText.split(whereSeparator: \.isNewline)

        #expect(swiftTermLines[1] == "swifterm-terminfo,")
        #expect(swiftTermLines.dropFirst(2).elementsEqual(fixtureLines.dropFirst(2)))
    }

    @Test func fixedGhosttyEntryCountsAndNames() throws {
        let fixture = try fixtureCapabilities()
        #expect(fixture.names == ["xterm-ghostty", "ghostty", "Ghostty"])
        let booleans = fixture.values.values.filter(\.isEmpty).count
        let numbers = fixture.values.values.filter { Int($0) != nil }.count
        let strings = fixture.values.count - booleans - numbers
        #expect(booleans == 15)
        #expect(numbers == 5)
        #expect(strings == 248)
        #expect(fixture.values.count == 268)
    }

    @Test func fixedGhosttyGapCapabilities() throws {
        let values = try fixtureCapabilities().values
        let expected: [String: String] = [
            "flash": "\\E[?5h$<100/>\\E[?5l",
            "XR": "\\E[>0q",
            "xr": "\\EP>\\\\|[ -~]+a\\E\\\\",
            "kent": "\\EOM",
            "blink": "\\E[5m",
            "kf3": "\\EOR",
            "kf63": "\\E[1;4R",
            "kDC7": "\\E[3;7~",
            "kUP7": "\\E[1;7A"
        ]
        for (name, expectedValue) in expected {
            #expect(values[name] == expectedValue, "Capability \(name) differs from the fixed entry")
        }
    }
}
