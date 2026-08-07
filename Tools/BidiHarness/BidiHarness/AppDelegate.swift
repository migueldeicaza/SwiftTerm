import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var controller: HarnessViewController?
    private var server: SocketControlServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        installMenu()

        do {
            let options = try LaunchOptions(arguments: ProcessInfo.processInfo.arguments)
            let store = try ScenarioStore()
            let controller = HarnessViewController(store: store, artifactRoot: options.artifactRoot, runID: options.runID)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1440, height: 650),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "SwiftTerm BiDi Harness"
            window.contentViewController = controller
            window.center()
            window.setFrameAutosaveName("SwiftTermBidiHarnessWindow")
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            self.window = window
            self.controller = controller

            let server = SocketControlServer(path: options.socketPath) { [weak controller] command in
                guard let controller else { throw HarnessError.io("The harness controller is unavailable") }
                return try controller.handle(command)
            }
            try server.start()
            self.server = server
            printStartup(socketPath: options.socketPath, artifactRoot: options.artifactRoot, runID: options.runID)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func installMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        mainMenu.addItem(applicationItem)
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "Quit BidiHarness", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        NSApplication.shared.mainMenu = mainMenu
    }

    private func printStartup(socketPath: String, artifactRoot: URL, runID: String) {
        let object: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "socket": socketPath,
            "artifactRoot": artifactRoot.path,
            "runID": runID,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0a]))
    }
}

struct LaunchOptions {
    var socketPath: String
    var artifactRoot: URL
    var runID: String

    init(arguments: [String]) throws {
        let temporary = FileManager.default.temporaryDirectory
        var socketPath = temporary.appendingPathComponent("swiftterm-bidi-\(ProcessInfo.processInfo.processIdentifier).sock").path
        var artifactRoot = temporary.appendingPathComponent("SwiftTermBidiHarnessArtifacts", isDirectory: true)
        var runID = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        var index = 1
        while index < arguments.count {
            let option = arguments[index]
            guard index + 1 < arguments.count else { throw HarnessError.invalidArgument("Missing value for \(option)") }
            let value = arguments[index + 1]
            switch option {
            case "--socket": socketPath = value
            case "--artifacts": artifactRoot = URL(fileURLWithPath: value, isDirectory: true)
            case "--run-id": runID = value
            default: throw HarnessError.invalidArgument("Unknown launch option: \(option)")
            }
            index += 2
        }
        guard !socketPath.isEmpty, !artifactRoot.path.isEmpty, !runID.safeArtifactComponent.isEmpty else {
            throw HarnessError.invalidArgument("The socket, artifact root, and run identifier must not be empty")
        }
        self.socketPath = socketPath
        self.artifactRoot = artifactRoot
        self.runID = runID
    }
}
