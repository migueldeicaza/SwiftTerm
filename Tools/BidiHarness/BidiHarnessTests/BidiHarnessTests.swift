import Foundation
import XCTest
@testable import BidiHarness

final class BidiHarnessTests: XCTestCase {
    func testJSONLineFramerHandlesFragmentsAndMultipleMessages() throws {
        var framer = JSONLineFramer(maximumMessageBytes: 100)
        XCTAssertTrue(try framer.append(Data("{\"id\":1".utf8)).isEmpty)
        let messages = try framer.append(Data("}\n{\"id\":2}\n".utf8))
        XCTAssertEqual(messages, [Data("{\"id\":1}".utf8), Data("{\"id\":2}".utf8)])
        XCTAssertTrue(framer.pending.isEmpty)
    }

    func testJSONLineFramerRejectsOversizeMessage() throws {
        var framer = JSONLineFramer(maximumMessageBytes: 4)
        XCTAssertThrowsError(try framer.append(Data("12345".utf8)))
    }

    func testCommandRoundTripPreservesNestedArguments() throws {
        let command = HarnessCommand(command: "drag", arguments: [
            "from": .object(["column": .number(4), "row": .number(2)]),
            "to": .object(["column": .number(9), "row": .number(2)]),
        ])
        let encoded = try JSONEncoder().encode(command)
        XCTAssertEqual(try JSONDecoder().decode(HarnessCommand.self, from: encoded), command)
    }

    func testScenarioValidationRejectsDuplicateSteps() throws {
        let step = ScenarioStep(id: "same", title: "Step", actions: [])
        let scenario = HarnessScenario(
            schemaVersion: 1,
            id: "valid-id",
            title: "Title",
            purpose: "Purpose",
            initial: ScenarioInitialState(),
            reference: ScenarioReference(text: "text"),
            steps: [step, step]
        )
        XCTAssertThrowsError(try scenario.validate())
    }

    func testArtifactNamesAreSanitized() {
        XCTAssertEqual("../../unsafe name".safeArtifactComponent, "unsafe-name")
        XCTAssertEqual("مرحبا".safeArtifactComponent, "مرحبا")
    }

    func testManifestAndLogicalTextAreWrittenTogether() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BidiHarnessTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = HarnessManifest(
            runID: "test-run",
            scenario: "scenario",
            step: "step",
            renderer: "coreGraphics",
            gitRevision: "abc",
            capturedAt: "2026-01-01T00:00:00Z",
            operatingSystem: "macOS",
            backingScale: 2,
            fontName: "Menlo",
            fontSize: 14,
            cols: 80,
            rows: 24,
            cursorColumn: 0,
            cursorRow: 0,
            viewportRow: 0,
            scrollPosition: 0,
            currentBidiState: "implicitAutoLeftToRight",
            arrowKeySwap: true,
            hostPolicy: "respectTerminal",
            customBlockGlyphs: true,
            selection: nil,
            outgoingBytesBase64: "",
            logicalBufferSHA256: ArtifactCapture.sha256("שלום"),
            visibleRows: [],
            assertions: [],
            timingsMilliseconds: ["setup.0.feed": 1.25],
            imagePath: ""
        )
        let result = try ArtifactCapture.write(
            pngData: Data([0x89, 0x50, 0x4e, 0x47]),
            logicalText: "שלום",
            manifest: manifest,
            root: root
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.imageURL.path))
        XCTAssertEqual(try String(contentsOf: result.logicalBufferURL, encoding: .utf8), "שלום")
        let decoded = try JSONDecoder().decode(HarnessManifest.self, from: Data(contentsOf: result.manifestURL))
        XCTAssertEqual(decoded.imagePath, result.imageURL.path)
        XCTAssertEqual(decoded.logicalBufferSHA256, ArtifactCapture.sha256("שלום"))
    }

    func testLaunchOptionsUseExplicitPaths() throws {
        let options = try LaunchOptions(arguments: [
            "BidiHarness", "--socket", "/tmp/bidi-test.sock",
            "--artifacts", "/tmp/bidi-artifacts", "--run-id", "run-1",
        ])
        XCTAssertEqual(options.socketPath, "/tmp/bidi-test.sock")
        XCTAssertEqual(options.artifactRoot.path, "/tmp/bidi-artifacts")
        XCTAssertEqual(options.runID, "run-1")
    }
}
