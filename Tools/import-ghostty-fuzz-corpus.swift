#!/usr/bin/env swift

import Foundation

private let corpusNames = [
    "osc-initial",
    "osc-cmin",
    "parser-initial",
    "parser-cmin",
    "stream-initial",
    "stream-cmin",
]

private enum ImportError: Error {
    case inputTooLarge(String)
}

private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data(
        "usage: import-ghostty-fuzz-corpus.swift /path/to/ghostty\n".utf8))
    exit(2)
}

let fileManager = FileManager.default
let ghosttyRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let outputRoot = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent("Tests/SwiftTermTests/Fixtures/GhosttyFuzzCorpus", isDirectory: true)
try fileManager.createDirectory(at: outputRoot, withIntermediateDirectories: true)

for corpusName in corpusNames {
    let inputRoot = ghosttyRoot
        .appendingPathComponent("test/fuzz-libghostty/corpus", isDirectory: true)
        .appendingPathComponent(corpusName, isDirectory: true)
    let inputURLs = try fileManager.contentsOfDirectory(
        at: inputRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles])
        .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    var archive = Data("STFZ1".utf8)
    appendLittleEndian(UInt32(inputURLs.count), to: &archive)
    for inputURL in inputURLs {
        let name = Data(inputURL.lastPathComponent.utf8)
        let input = try Data(contentsOf: inputURL)
        guard name.count <= Int(UInt16.max), input.count <= Int(UInt32.max) else {
            throw ImportError.inputTooLarge(inputURL.path)
        }
        appendLittleEndian(UInt16(name.count), to: &archive)
        archive.append(name)
        appendLittleEndian(UInt32(input.count), to: &archive)
        archive.append(input)
    }

    try archive.write(
        to: outputRoot.appendingPathComponent("\(corpusName).stfuzz"),
        options: .atomic)
    print("Imported \(inputURLs.count) inputs from \(corpusName)")
}
