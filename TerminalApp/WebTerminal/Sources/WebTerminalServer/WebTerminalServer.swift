import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
struct WebTerminalServer {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] || arguments == ["-h"] {
            print(ServerConfiguration.usage)
            return
        }
        do {
            let configuration = try ServerConfiguration(arguments: arguments)
            try configuration.validateAssets()
            print("Open http://127.0.0.1:\(configuration.port)")
            print("Shell: \(configuration.shell) | Directory: \(configuration.directory)")
            try await runServer(configuration: configuration)
        } catch {
            FileHandle.standardError.write(Data("web-terminal: \(error)\n".utf8))
            exit(1)
        }
    }
}
