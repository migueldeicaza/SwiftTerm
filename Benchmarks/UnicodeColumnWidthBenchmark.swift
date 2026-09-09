import Dispatch
import Foundation

@main
struct UnicodeColumnWidthBenchmark {
    private static let corpus = """
        ASCII and Latin: The quick brown fox; café; naïve. \
        Combining: e\u{0301} a\u{20D1}. \
        CJK: 日本語 漢字. \
        Hangul: 한글 \u{1100}\u{1161}. \
        Emoji: 😀👍🏽. \
        Regional indicators: 🇺🇸. \
        Supplementary narrow: \u{10000}\u{10400}\u{1D400}.
        """

    static func main ()
    {
        // Read through the environment so that the compiler cannot replace the
        // fixed corpus and width calls with constants.
        let input = ProcessInfo.processInfo.environment ["SWIFTTERM_WIDTH_CORPUS"] ?? corpus
        let scalars = Array (input.unicodeScalars)
        let iterations = Int (ProcessInfo.processInfo.environment ["SWIFTTERM_WIDTH_ITERATIONS"] ?? "") ?? 200_000
        var samples: [Double] = []
        var checksum = 0

        for _ in 0..<5 {
            let start = DispatchTime.now ().uptimeNanoseconds
            for _ in 0..<iterations {
                for scalar in scalars {
                    checksum &+= UnicodeUtil.columnWidth (rune: scalar)
                }
            }
            let nanoseconds = DispatchTime.now ().uptimeNanoseconds - start
            samples.append (Double (nanoseconds) / 1_000_000)
        }

        samples.sort ()
        print ("scalars=\(scalars.count) calls-per-sample=\(scalars.count * iterations) " +
               "median-ms=\(samples [2]) samples-ms=\(samples) checksum=\(checksum)")
    }
}
