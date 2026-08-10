import Foundation
import PackagePlugin

@main
struct SwiftTermBuildInfoPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let generator = try context.tool(named: "SwiftTermBuildInfoGenerator")
        let outputDirectory = context.pluginWorkDirectoryURL.appendingPathComponent("Generated")
        let outputFile = outputDirectory.appendingPathComponent("SwiftTermBuildInfo.swift")
        let triggerFile = context.pluginWorkDirectoryURL.appendingPathComponent("build-info-trigger")
        let fallbackVariableNames = [
            "SWIFTTERM_BUILD_BRANCH",
            "SWIFTTERM_BUILD_TAG",
            "SWIFTTERM_BUILD_COMMIT",
            "SWIFTTERM_BUILD_DIRTY"
        ]
        let processEnvironment = ProcessInfo.processInfo.environment
        let fallbackEnvironment = fallbackVariableNames.reduce(into: [String: String]()) { result, name in
            if let value = processEnvironment[name] {
                result[name] = value
            }
        }

        try FileManager.default.createDirectory(
            at: context.pluginWorkDirectoryURL,
            withIntermediateDirectories: true
        )
        try UUID().uuidString.write(to: triggerFile, atomically: true, encoding: .utf8)

        return [
            .buildCommand(
                displayName: "Generate SwiftTerm build information",
                executable: generator.url,
                arguments: [
                    context.package.directoryURL.path,
                    outputFile.path
                ],
                environment: fallbackEnvironment,
                inputFiles: [triggerFile],
                outputFiles: [outputFile]
            )
        ]
    }
}
