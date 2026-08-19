import Foundation
import PackagePlugin

@main
struct SwiftTermBuildInfoPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let generator = try context.tool(named: "SwiftTermBuildInfoGenerator")
        let outputDirectory = context.pluginWorkDirectoryURL.appendingPathComponent("Generated")
        let outputFile = outputDirectory.appendingPathComponent("SwiftTermBuildInfo.swift")
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
        let inputFiles = stableInputFiles(
            in: context.package.directoryURL,
            for: target
        )

        return [
            .buildCommand(
                displayName: "Generate SwiftTerm build information",
                executable: generator.url,
                arguments: [
                    context.package.directoryURL.path,
                    outputFile.path
                ],
                environment: fallbackEnvironment,
                inputFiles: inputFiles,
                outputFiles: [outputFile]
            )
        ]
    }

    /// Files that can change the generated source-control information.
    private func stableInputFiles(in repositoryURL: URL, for target: Target) -> [URL] {
        var filesByPath: [String: URL] = [:]

        if let sourceTarget = target as? SourceModuleTarget {
            for file in sourceTarget.sourceFiles {
                filesByPath[file.url.path] = file.url
            }
        }
        addFileIfPresent(
            repositoryURL.appendingPathComponent("Package.swift"),
            to: &filesByPath
        )
        addGitStateFiles(at: repositoryURL, to: &filesByPath)

        return filesByPath.values.sorted { $0.path < $1.path }
    }

    /// Add the files that identify HEAD, refs, and tags.
    private func addGitStateFiles(at repositoryURL: URL, to filesByPath: inout [String: URL]) {
        let dotGitURL = repositoryURL.appendingPathComponent(".git")
        guard let gitDirectoryURL = gitDirectoryURL(from: dotGitURL) else {
            return
        }
        let commonDirectoryURL = commonDirectoryURL(from: gitDirectoryURL)

        addFileIfPresent(dotGitURL, to: &filesByPath)
        let headURL = gitDirectoryURL.appendingPathComponent("HEAD")
        addFileIfPresent(headURL, to: &filesByPath)
        addFileIfPresent(gitDirectoryURL.appendingPathComponent("commondir"), to: &filesByPath)

        for directoryURL in Set([gitDirectoryURL, commonDirectoryURL]) {
            addFileIfPresent(directoryURL.appendingPathComponent("packed-refs"), to: &filesByPath)
            addFilesRecursively(at: directoryURL.appendingPathComponent("refs/tags"), to: &filesByPath)
        }

        if let reference = symbolicReference(in: headURL) {
            for directoryURL in Set([gitDirectoryURL, commonDirectoryURL]) {
                addFileIfPresent(directoryURL.appendingPathComponent(reference), to: &filesByPath)
            }
        }
    }

    private func symbolicReference(in headURL: URL) -> String? {
        guard let contents = try? String(contentsOf: headURL, encoding: .utf8),
              contents.hasPrefix("ref: ") else {
            return nil
        }
        return contents
            .dropFirst("ref: ".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func gitDirectoryURL(from dotGitURL: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGitURL.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            return dotGitURL
        }

        guard let contents = try? String(contentsOf: dotGitURL, encoding: .utf8),
              contents.hasPrefix("gitdir: ") else {
            return nil
        }
        let path = contents
            .dropFirst("gitdir: ".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if (path as NSString).isAbsolutePath {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return repositoryURL(for: dotGitURL)
            .appendingPathComponent(path)
            .standardizedFileURL
    }

    private func commonDirectoryURL(from gitDirectoryURL: URL) -> URL {
        let commonDirectoryFileURL = gitDirectoryURL.appendingPathComponent("commondir")
        guard let contents = try? String(contentsOf: commonDirectoryFileURL, encoding: .utf8) else {
            return gitDirectoryURL
        }
        let path = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if (path as NSString).isAbsolutePath {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return gitDirectoryURL.appendingPathComponent(path).standardizedFileURL
    }

    private func repositoryURL(for dotGitURL: URL) -> URL {
        dotGitURL.deletingLastPathComponent()
    }

    private func addFilesRecursively(at directoryURL: URL, to filesByPath: inout [String: URL]) {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else {
            return
        }

        for case let fileURL as URL in enumerator {
            addFileIfPresent(fileURL, to: &filesByPath)
        }
    }

    private func addFileIfPresent(_ fileURL: URL, to filesByPath: inout [String: URL]) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return
        }
        filesByPath[fileURL.path] = fileURL
    }
}
