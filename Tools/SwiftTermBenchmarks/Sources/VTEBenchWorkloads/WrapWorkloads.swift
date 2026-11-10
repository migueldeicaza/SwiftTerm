/// Text with no line feed, so each row ends in an automatic wrap. These cases
/// measure the wrap at the end of the row in the print paths.
extension VTEBenchWorkloads {
    public static func makeWrap(
        columns: Int = defaultColumns,
        rows: Int = defaultRows
    ) -> [VTEBenchWorkload] {
        precondition(columns > 0 && rows > 0, "Terminal dimensions must be positive")
        // 45 characters: not a factor of the row width, so the runs that the
        // parser gives the print path end at different columns.
        let sentence = "The quick brown fox jumps over the lazy dog. "
        // Five wide characters and one narrow character: 11 columns. On an
        // even row width, a wide character is on the last column for half
        // of the rows, and must wrap before it is written.
        let wideGroup = "界語中文字a"
        return [
            VTEBenchWorkload(
                name: "wrap_ascii",
                payload: Array(String(repeating: sentence, count: 64).utf8)),
            VTEBenchWorkload(
                name: "wrap_cjk",
                payload: Array(String(repeating: wideGroup, count: 256).utf8))
        ].map { $0.sized(columns: columns, rows: rows) }
    }
}
