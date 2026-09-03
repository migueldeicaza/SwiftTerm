import Foundation

@main
struct BuildInfoGenerator {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else {
            throw GeneratorError.invalidArguments
        }

        let repositoryPath = CommandLine.arguments[1]
        let outputFile = URL(fileURLWithPath: CommandLine.arguments[2])
        let terminfoOutputFile = URL(fileURLWithPath: CommandLine.arguments[3])
        let outputDirectory = outputFile.deletingLastPathComponent()
        let environment = ProcessInfo.processInfo.environment
        let repository = GitRepository(repositoryPath: repositoryPath)
        let git = GitCommand(repositoryPath: repositoryPath)

        let branch = environment.nonemptyValue(for: "SWIFTTERM_BUILD_BRANCH")
            ?? repository.branch
            ?? git.nonemptyOutput(for: ["branch", "--show-current"])
        let tag = environment.nonemptyValue(for: "SWIFTTERM_BUILD_TAG")
            ?? git.nonemptyOutput(for: ["describe", "--exact-match", "--tags"])
        let commit = environment.nonemptyValue(for: "SWIFTTERM_BUILD_COMMIT")
            ?? repository.commit
            ?? git.nonemptyOutput(for: ["rev-parse", "HEAD"])
        let hasUncommittedChanges = environment.booleanValue(for: "SWIFTTERM_BUILD_DIRTY")
            ?? git.output(for: ["status", "--porcelain"]).map { !$0.isEmpty }

        let source = sourceFile(
            branch: branch,
            tag: tag,
            commit: commit,
            hasUncommittedChanges: hasUncommittedChanges
        )

        let terminfoPath = URL(fileURLWithPath: repositoryPath, isDirectory: true)
            .appendingPathComponent("swifterm-terminfo").path
        let terminfoSource: String
        do {
            terminfoSource = try XtgettcapTableGenerator.sourceFile(
                capabilities: TerminfoSource.capabilities(atPath: terminfoPath)
            )
        } catch let error as TerminfoSourceError {
            FileHandle.standardError.write(Data("error: \(error.description)\n".utf8))
            exit(1)
        }

        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: terminfoOutputFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try write(source, to: outputFile)
        try write(terminfoSource, to: terminfoOutputFile)
    }

    /// Writes only when the content changes, so an unchanged input does not
    /// force the dependent target to rebuild.
    private static func write(_ source: String, to file: URL) throws {
        let existingSource = try? String(contentsOf: file, encoding: .utf8)
        if existingSource != source {
            try source.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    private static func sourceFile(
        branch: String?,
        tag: String?,
        commit: String?,
        hasUncommittedChanges: Bool?
    ) -> String {
        let branchLiteral = optionalStringLiteral(branch)
        let tagLiteral = optionalStringLiteral(tag)
        let commitLiteral = optionalStringLiteral(commit)
        let dirtyLiteral = optionalBooleanLiteral(hasUncommittedChanges)

        return """
        // This file is generated. Do not edit it.

        /// Source-control information for this SwiftTerm build.
        public enum SwiftTermBuildInfo {
            /// The Git branch, if the build uses a branch checkout.
            public static let branch: String? = \(branchLiteral)

            /// The exact Git tag for the current commit, if one is available.
            public static let tag: String? = \(tagLiteral)

            /// The full Git commit identifier, if one is available.
            public static let commit: String? = \(commitLiteral)

            /// Whether the repository had uncommitted changes during the build.
            ///
            /// This value is `nil` when neither Git nor an environment fallback
            /// can determine the worktree state.
            public static let hasUncommittedChanges: Bool? = \(dirtyLiteral)

            /// A value suitable for display in logs and diagnostic output.
            ///
            /// This value uses the exact tag when available. Otherwise, it uses the
            /// first 12 characters of the commit identifier. It is `"unknown"` when
            /// the package has no Git information. Modified builds have a `-modified`
            /// suffix.
            public static let version: String = {
                let base = tag ?? commit.map { String($0.prefix(12)) } ?? "unknown"
                return hasUncommittedChanges == true ? "\\(base)-modified" : base
            }()
        }

        """
    }

    private static func optionalStringLiteral(_ value: String?) -> String {
        value.map { String(reflecting: $0) } ?? "nil"
    }

    private static func optionalBooleanLiteral(_ value: Bool?) -> String {
        value.map(String.init) ?? "nil"
    }
}

private struct GitRepository {
    let repositoryURL: URL

    init(repositoryPath: String) {
        repositoryURL = URL(fileURLWithPath: repositoryPath, isDirectory: true)
    }

    var branch: String? {
        guard let reference = head.reference, reference.hasPrefix("refs/heads/") else {
            return nil
        }

        return String(reference.dropFirst("refs/heads/".count))
    }

    var commit: String? {
        if let commit = head.commit {
            return commit
        }

        guard let reference = head.reference else {
            return nil
        }

        return resolve(reference: reference)
    }

    private var head: (reference: String?, commit: String?) {
        guard let gitDirectory,
              let value = read(gitDirectory.appendingPathComponent("HEAD")) else {
            return (nil, nil)
        }

        if value.hasPrefix("ref: ") {
            return (String(value.dropFirst("ref: ".count)), nil)
        }

        return (nil, value)
    }

    private var gitDirectory: URL? {
        let dotGit = repositoryURL.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false

        if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                return dotGit
            }

            if let value = read(dotGit), value.hasPrefix("gitdir: ") {
                let path = String(value.dropFirst("gitdir: ".count))
                if (path as NSString).isAbsolutePath {
                    return URL(fileURLWithPath: path, isDirectory: true)
                }
                return repositoryURL.appendingPathComponent(path).standardizedFileURL
            }
        }

        return nil
    }

    private var commonDirectory: URL? {
        guard let gitDirectory else {
            return nil
        }

        guard let path = read(gitDirectory.appendingPathComponent("commondir")) else {
            return gitDirectory
        }

        if (path as NSString).isAbsolutePath {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return gitDirectory.appendingPathComponent(path).standardizedFileURL
    }

    private func resolve(reference: String) -> String? {
        if let gitDirectory,
           let value = read(gitDirectory.appendingPathComponent(reference)) {
            return value
        }

        if let commonDirectory,
           let value = read(commonDirectory.appendingPathComponent(reference)) {
            return value
        }

        for directory in [gitDirectory, commonDirectory].compactMap({ $0 }) {
            guard let packedReferences = try? String(
                contentsOf: directory.appendingPathComponent("packed-refs"),
                encoding: .utf8
            ) else {
                continue
            }

            for line in packedReferences.split(whereSeparator: \.isNewline) {
                let fields = line.split(separator: " ", maxSplits: 1)
                if fields.count == 2, fields[1] == reference {
                    return String(fields[0])
                }
            }
        }

        return nil
    }

    private func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct GitCommand {
    let repositoryPath: String

    func nonemptyOutput(for arguments: [String]) -> String? {
        guard let value = output(for: arguments), !value.isEmpty else {
            return nil
        }
        return value
    }

    func output(for arguments: [String]) -> String? {
#if os(macOS) || os(Linux) || os(Windows)
        guard let gitURL = gitExecutableURL else {
            return nil
        }

        let process = Process()
        let standardOutput = Pipe()
        process.executableURL = gitURL
        process.arguments = ["-C", repositoryPath] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["GIT_OPTIONAL_LOCKS": "0"],
            uniquingKeysWith: { _, newValue in newValue }
        )
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = standardOutput.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                return nil
            }

            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
#else
        return nil
#endif
    }

    private var gitExecutableURL: URL? {
#if os(macOS)
        let url = URL(fileURLWithPath: "/usr/bin/git")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
#else
        return executable(named: "git")
#endif
    }

    private func executable(named name: String) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let separator: Character = {
            #if os(Windows)
            ";"
            #else
            ":"
            #endif
        }()
        let executableName: String = {
            #if os(Windows)
            "\(name).exe"
            #else
            name
            #endif
        }()

        return environment["PATH"]?
            .split(separator: separator)
            .lazy
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
            .map { $0.appendingPathComponent(executableName) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

private extension Dictionary where Key == String, Value == String {
    func nonemptyValue(for key: String) -> String? {
        guard let value = self[key], !value.isEmpty else {
            return nil
        }
        return value
    }

    func booleanValue(for key: String) -> Bool? {
        switch self[key]?.lowercased() {
        case "1", "true", "yes":
            true
        case "0", "false", "no":
            false
        default:
            nil
        }
    }
}

private enum GeneratorError: Error {
    case invalidArguments
}
