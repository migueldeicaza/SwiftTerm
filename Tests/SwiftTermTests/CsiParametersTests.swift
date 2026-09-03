import Testing
@testable import SwiftTerm

final class CsiParametersTests {
    @Test func storageAppendsToCapacityAndViewReadsBack() {
        var storage = CsiParameterStorage()
        for value in 0..<EscapeSequenceParser.maximumParameterCount {
            storage.append(value * 3)
        }
        #expect(storage.count == EscapeSequenceParser.maximumParameterCount)
        storage.withView { view in
            #expect(view.count == EscapeSequenceParser.maximumParameterCount)
            #expect(Array(view) == (0..<EscapeSequenceParser.maximumParameterCount).map { $0 * 3 })
            #expect(view[23] == 69)
        }
    }

    @Test func resetProducesExactlyOneZeroParameter() {
        var storage = CsiParameterStorage()
        storage.append(7)
        storage.append(8)
        storage.reset()
        #expect(storage.count == 1)
        storage.withView { view in
            #expect(view == [0])
            #expect(view.first == 0)
        }
    }

    @Test func accumulateDigitBuildsAndClampsTheLastParameter() {
        var storage = CsiParameterStorage()
        storage.reset()
        for digit in "123".utf8 { storage.accumulateDigit(digit) }
        storage.append(0)
        for digit in "45".utf8 { storage.accumulateDigit(digit) }
        storage.withView { view in #expect(view == [123, 45]) }

        for digit in "99999999999".utf8 { storage.accumulateDigit(digit) }
        storage.withView { view in
            #expect(view[1] == EscapeSequenceParser.maximumParameterValue)
        }
    }

    @Test func viewSupportsRandomAccessCollectionOperations() {
        var storage = CsiParameterStorage()
        for value in [38, 2, 10, 20, 30] { storage.append(value) }
        storage.withView { view in
            #expect(view.count == 5)
            #expect(!view.isEmpty)
            #expect(view.first == 38)
            #expect(view.last == 30)
            #expect(Array(view.dropFirst(2)) == [10, 20, 30])
            #expect(Array(view.prefix(2)) == [38, 2])
            #expect(view.map { $0 + 1 } == [39, 3, 11, 21, 31])
            #expect(Array(view[1...]) == [2, 10, 20, 30])
            var seen: [Int] = []
            for value in view { seen.append(value) }
            #expect(seen == [38, 2, 10, 20, 30])
        }
    }

    @Test func viewComparesAgainstArraysByActiveElementsOnly() {
        var storage = CsiParameterStorage()
        storage.append(0)
        storage.append(5)
        storage.withView { view in
            #expect(view == [0, 5])
            #expect(!(view == [0]))
            #expect(!(view == [0, 5, 0]))
        }
        storage.reset()
        storage.withView { view in #expect(view == [0]) }
    }
}
