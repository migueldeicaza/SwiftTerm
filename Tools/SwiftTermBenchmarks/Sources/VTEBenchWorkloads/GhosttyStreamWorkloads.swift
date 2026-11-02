/// Fixed streams based on the input classes in Ghostty's terminal-stream
/// benchmark. These are Swift generators, not copies of Ghostty corpus files.
extension VTEBenchWorkloads {
    public static func makeGhosttyStream() -> [VTEBenchWorkload] {
        let columns = 120
        let rows = 80
        let chunk = 64 * 1024

        func workload(_ name: String, _ payload: [UInt8]) -> VTEBenchWorkload {
            VTEBenchWorkload(name: "ghostty_\(name)", payload: payload,
                             columns: columns, rows: rows, inputChunkSize: chunk)
        }

        return [
            workload("ascii", Array(String(repeating: "The quick brown fox jumps over the lazy dog. ",
                                            count: 1_457).utf8)),
            workload("utf8", utf8Stream()),
            workload("osc", oscStream()),
            workload("styled_plain", styledStream(styleRate: 0, attributesPerSGR: 1)),
            workload("styled_single", styledStream(styleRate: 10, attributesPerSGR: 3,
                                                     splitAttributes: true)),
            workload("styled_heavy", styledStream(styleRate: 8, attributesPerSGR: 1)),
            workload("styled_multi", styledStream(styleRate: 10, attributesPerSGR: 3)),
            workload("styled_mixed", styledStream(styleRate: 3, attributesPerSGR: 1,
                                                    mixed: true))
        ]
    }

    private static func utf8Stream() -> [UInt8] {
        let scalars = ["A", "é", "界", "😀", "B", "ñ", "語", "🚀"]
        var result: [UInt8] = []
        result.reserveCapacity(66_000)
        for index in 0..<32_000 {
            result.append(contentsOf: scalars[index % scalars.count].utf8)
        }
        return result
    }

    private static func oscStream() -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(66_000)
        for index in 0..<4_000 {
            let sequence: String
            switch index % 4 {
            case 0: sequence = "\u{1b}]2;title \(index)\u{07}"
            case 1: sequence = "\u{1b}]8;;https://example.com/\(index)\u{1b}\\"
            case 2: sequence = "text\u{1b}]8;;\u{1b}\\\r\n"
            default: sequence = "\u{1b}]9;ignored \(index)\u{07}"
            }
            result.append(contentsOf: sequence.utf8)
        }
        return result
    }

    /// Lines have 40-80 printable characters, 4-16 characters per run, and
    /// CR LF endings, as in Ghostty's `styled` generator. A run number selects
    /// characters and styles so the single and multi cases print the same text.
    private static func styledStream(
        styleRate: Int,
        attributesPerSGR: Int,
        splitAttributes: Bool = false,
        mixed: Bool = false
    ) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(75_000)
        var run = 0
        var line = 0

        while line < 1_200 {
            var remaining = 40 + (line * 17 % 41)
            var styled = false
            var linkOpen = false
            while remaining > 0 {
                let runLength = min(remaining, 4 + (run * 7 % 13))
                if run % 10 < styleRate {
                    result.append(contentsOf: sgr(run: run, count: attributesPerSGR,
                                                  splitAttributes: splitAttributes).utf8)
                    styled = true
                }
                if mixed && run % 10 == 0 {
                    let link = linkOpen ? "\u{1b}]8;;\u{1b}\\"
                        : "\u{1b}]8;;https://example.com/\(run % 1024)\u{1b}\\"
                    result.append(contentsOf: link.utf8)
                    linkOpen.toggle()
                }
                for offset in 0..<runLength {
                    let index = run * 19 + offset * 7
                    if mixed {
                        let character = ["a", "b", "é", "界", "🙂", " "][index % 6]
                        result.append(contentsOf: character.utf8)
                        if index % 20 == 0 {
                            result.append(contentsOf: "\u{0301}".utf8)
                        }
                    } else {
                        result.append(UInt8(33 + index % 94))
                    }
                }
                remaining -= runLength
                run += 1
            }
            if styled { result.append(contentsOf: "\u{1b}[0m".utf8) }
            if linkOpen { result.append(contentsOf: "\u{1b}]8;;\u{1b}\\".utf8) }
            result.append(contentsOf: [13, 10])
            line += 1
        }
        return result
    }

    private static func sgr(run: Int, count: Int, splitAttributes: Bool) -> String {
        var attributes: [String] = []
        for offset in 0..<count {
            switch (run + offset) % 8 {
            case 0 where offset == 0: attributes.append("0")
            case 1: attributes.append("\(30 + run % 8)")
            case 2: attributes.append("\(40 + run % 8)")
            case 3: attributes.append("38;5;\(run % 256)")
            case 4: attributes.append("48;5;\((run * 3) % 256)")
            case 5: attributes.append("38;2;\(run % 6 * 51);\((run + 2) % 6 * 51);\((run + 4) % 6 * 51)")
            case 6: attributes.append("48;2;\(run % 6 * 51);\((run + 1) % 6 * 51);\((run + 3) % 6 * 51)")
            default: attributes.append(["1", "3", "4", "7", "9"][run % 5])
            }
        }
        if splitAttributes {
            return attributes.map { "\u{1b}[\($0)m" }.joined()
        }
        return "\u{1b}[\(attributes.joined(separator: ";"))m"
    }
}
