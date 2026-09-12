import Foundation

struct ServerConfiguration: Sendable {
    var port = 8080
    var shell: String
    var directory: String
    var publicDirectory: String
    var assetDirectory: String

    static let usage = """
    Usage: web-terminal [--port 8080] [--shell /bin/zsh] [--directory PATH]
                        [--public-directory PATH] [--web-assets PATH]

    Open http://127.0.0.1:8080. Each browser connection starts a local shell.
    The server accepts loopback connections only. Press Control-C to stop it.
    """

    init(arguments: [String] = [], environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = package.deletingLastPathComponent().deletingLastPathComponent()
        shell = environment["SHELL"] ?? "/bin/sh"
        if !shell.hasPrefix("/") || !FileManager.default.isExecutableFile(atPath: shell) { shell = "/bin/sh" }
        directory = FileManager.default.currentDirectoryPath
        publicDirectory = package.appendingPathComponent("Public").path
        assetDirectory = root.appendingPathComponent("Web/dist").path
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard index + 1 < arguments.count else { throw ConfigurationError("Missing value for \(option).") }
            let value = arguments[index + 1]
            switch option {
            case "--port":
                guard let number = Int(value), (1...65535).contains(number) else {
                    throw ConfigurationError("The port must be from 1 to 65535.")
                }
                port = number
            case "--shell": shell = value
            case "--directory": directory = URL(fileURLWithPath: value).standardizedFileURL.path
            case "--public-directory": publicDirectory = URL(fileURLWithPath: value).standardizedFileURL.path
            case "--web-assets": assetDirectory = URL(fileURLWithPath: value).standardizedFileURL.path
            default: throw ConfigurationError("Unknown option: \(option).")
            }
            index += 2
        }
        guard shell.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: shell) else {
            throw ConfigurationError("The shell must be an absolute path to an executable file.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ConfigurationError("The working directory does not exist: \(directory).")
        }
    }

    func validateAssets() throws {
        for path in ["index.js", "example/canvas2d.js", "swiftterm-full.wasm"] {
            guard FileManager.default.isReadableFile(atPath: assetDirectory + "/" + path) else {
                throw ConfigurationError("Missing Web asset: \(path). Run scripts/build-wasm.sh embedded --browser --release from the repository root.")
            }
        }
        guard FileManager.default.isReadableFile(atPath: publicDirectory + "/index.html") else {
            throw ConfigurationError("The sample page is missing from \(publicDirectory).")
        }
    }
}

struct ConfigurationError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
