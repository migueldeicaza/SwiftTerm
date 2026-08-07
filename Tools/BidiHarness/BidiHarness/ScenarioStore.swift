import Foundation

final class ScenarioStore {
    private(set) var scenarios: [HarnessScenario] = []
    private let bundle: Bundle

    init(bundle: Bundle = .main) throws {
        self.bundle = bundle
        try reload()
    }

    func reload() throws {
        let decoder = JSONDecoder()
        let nested = bundle.urls(forResourcesWithExtension: "json", subdirectory: "Scenarios") ?? []
        let flat = bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        let urls = Array(Set(nested + flat)).sorted { $0.lastPathComponent < $1.lastPathComponent }
        scenarios = try urls.map { url in
            let scenario = try decoder.decode(HarnessScenario.self, from: Data(contentsOf: url))
            try scenario.validate()
            return scenario
        }.sorted { $0.id < $1.id }
        guard !scenarios.isEmpty else {
            throw HarnessError.invalidScenario("The application bundle contains no scenarios")
        }
    }

    func scenario(id: String) throws -> HarnessScenario {
        guard let scenario = scenarios.first(where: { $0.id == id }) else {
            throw HarnessError.notFound("Unknown scenario: \(id)")
        }
        return scenario
    }

    func fixture(named name: String) throws -> String {
        let source = URL(fileURLWithPath: name)
        let resourceName = source.deletingPathExtension().lastPathComponent
        let resourceExtension = source.pathExtension.isEmpty ? nil : source.pathExtension
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension) else {
            throw HarnessError.notFound("Missing fixture: \(name)")
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw HarnessError.io("Could not read fixture \(name): \(error.localizedDescription)")
        }
    }

    func referenceText(for scenario: HarnessScenario) throws -> String {
        try referenceText(for: scenario.reference)
    }

    func referenceText(for reference: ScenarioReference) throws -> String {
        if let lines = reference.lines {
            return lines.map(\.text).joined(separator: "\n")
        }
        if let text = reference.text {
            return text
        }
        if let fixture = reference.fixture {
            return try self.fixture(named: fixture)
        }
        return ""
    }
}
