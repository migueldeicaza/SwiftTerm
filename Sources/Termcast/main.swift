import Foundation
import ArgumentParser
import SwiftTerm

struct Termcast: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record and replay terminal sessions.",
        subcommands: [Record.self, Playback.self]
    )
}

struct Record: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Record a terminal session."
    )

    @Argument(help: "The path to the file to save the recording.")
    var filePath: String

    @Option(name: .shortAndLong, help: "The command to execute. Defaults to the user's shell.")
    var command: String?

    @Option(name: .shortAndLong, help: "Timeout in seconds to automatically stop recording.")
    var timeout: Double?

    func run() throws {
        let recorder = TermcastRecorder()
        try recorder.record(to: filePath, command: command, timeout: timeout)
    }
}

struct Playback: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "playback",
        abstract: "Playback a recorded terminal session."
    )

    @Argument(help: "The path to the .cast file to replay.")
    var filePath: String

    func run() throws {
        let player = TermcastPlayer()
        try player.playback(from: filePath)
    }
}

Termcast.main()