//
//  SearchLineCache.swift
//  SwiftTerm
//
//  Ported from xterm.js search addon infrastructure.
//

import Foundation

typealias LineCacheEntry = (lineAsString: String, lineOffsets: [Int])

final class SearchLineCache {
    private enum Constants {
        static let linesCacheTimeToLive: TimeInterval = 15.0
    }

    private let terminal: Terminal
    private var linesCache: [LineCacheEntry?]?
    private var lastAccessTimestamp: TimeInterval = 0

    init (terminal: Terminal) {
        self.terminal = terminal
    }

    func initLinesCache () {
        let now = Date().timeIntervalSinceReferenceDate
        let bufferLineCount = terminal.displayBuffer.lines.count

        if let cache = linesCache {
            if now - lastAccessTimestamp >= Constants.linesCacheTimeToLive || cache.count != bufferLineCount {
                linesCache = nil
            }
        }

        if linesCache == nil {
            linesCache = Array(repeating: nil, count: bufferLineCount)
        }

        lastAccessTimestamp = now
    }

    func invalidate () {
        linesCache = nil
        lastAccessTimestamp = 0
    }

    func getLineFromCache (row: Int) -> LineCacheEntry? {
        guard let cache = linesCache, row >= 0, row < cache.count else {
            return nil
        }
        return cache[row]
    }

    func setLineInCache (row: Int, entry: LineCacheEntry) {
        guard row >= 0, row < (linesCache?.count ?? 0) else {
            return
        }
        linesCache?[row] = entry
    }

    func translateBufferLineToStringWithWrap (lineIndex: Int, trimRight: Bool) -> LineCacheEntry {
        let buffer = terminal.displayBuffer
        var strings: [String] = []
        var lineOffsets: [Int] = [0]
        var idx = lineIndex

        while idx >= 0 && idx < buffer.lines.count {
            let line = buffer.lines[idx]
            let nextLine = (idx + 1) < buffer.lines.count ? buffer.lines[idx + 1] : nil
            let lineWrapsToNext = nextLine?.isWrapped ?? false

            var string = buffer.translateBufferLineToString(
                lineIndex: idx,
                trimRight: !lineWrapsToNext && trimRight,
                startCol: 0,
                endCol: -1,
                skipNullCellsFollowingWide: true,
                characterProvider: { self.terminal.getCharacter(for: $0) }
            ).replacingOccurrences(of: "\u{0}", with: " ")

            if lineWrapsToNext, let nextLine {
                let lastIndex = max(line.count - 1, 0)
                let lastCell = line[lastIndex]
                let lastCellIsNull = lastCell.code == 0 && lastCell.width <= 1
                if lastCellIsNull && nextLine.getWidth(index: 0) == 2 {
                    if !string.isEmpty {
                        string.removeLast()
                    }
                }
            }

            strings.append(string)

            if lineWrapsToNext {
                lineOffsets.append(lineOffsets[lineOffsets.count - 1] + string.count)
            } else {
                break
            }

            idx += 1
        }

        return (strings.joined(), lineOffsets)
    }
}
