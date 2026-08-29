// Helpers for the UTF-16 offsets that platform text-input APIs use.
import Foundation

enum TextInputUTF16Rounding {
    case backward
    case forward
}

extension String {
    var textInputUTF16Count: Int {
        utf16.count
    }

    func textInputIndex(atUTF16Offset offset: Int, rounding: TextInputUTF16Rounding) -> String.Index {
        let clampedOffset = max(0, min(offset, utf16.count))

        func index(at offset: Int) -> String.Index? {
            let utf16Index = utf16.index(utf16.startIndex, offsetBy: offset)
            return String.Index(utf16Index, within: self)
        }

        if let exactIndex = index(at: clampedOffset) {
            return exactIndex
        }

        switch rounding {
        case .backward:
            var candidate = clampedOffset
            while candidate > 0 {
                candidate -= 1
                if let roundedIndex = index(at: candidate) {
                    return roundedIndex
                }
            }
            return startIndex
        case .forward:
            var candidate = clampedOffset
            while candidate < utf16.count {
                candidate += 1
                if let roundedIndex = index(at: candidate) {
                    return roundedIndex
                }
            }
            return endIndex
        }
    }

    func textInputUTF16Offset(of index: String.Index) -> Int {
        guard let utf16Index = index.samePosition(in: utf16) else {
            return utf16.count
        }
        return utf16.distance(from: utf16.startIndex, to: utf16Index)
    }

    func textInputValidUTF16Offset(_ offset: Int, rounding: TextInputUTF16Rounding) -> Int {
        textInputUTF16Offset(of: textInputIndex(atUTF16Offset: offset, rounding: rounding))
    }

    func textInputOffset(_ offset: Int, advancedByUTF16Distance distance: Int) -> Int {
        let rawOffset = max(0, min(offset + distance, utf16.count))
        return textInputValidUTF16Offset(rawOffset, rounding: distance < 0 ? .backward : .forward)
    }

    func textInputRange(startUTF16Offset: Int, endUTF16Offset: Int) -> Range<String.Index> {
        let startOffset = max(0, min(startUTF16Offset, utf16.count))
        let endOffset = max(startOffset, min(endUTF16Offset, utf16.count))

        if startOffset == endOffset {
            let insertionIndex = textInputIndex(atUTF16Offset: startOffset, rounding: .forward)
            return insertionIndex..<insertionIndex
        }

        let lowerBound = textInputIndex(atUTF16Offset: startOffset, rounding: .backward)
        let upperBound = textInputIndex(atUTF16Offset: endOffset, rounding: .forward)
        return lowerBound..<upperBound
    }

    func textInputCharacterRange(beforeUTF16Offset offset: Int) -> Range<String.Index>? {
        let endIndex = textInputIndex(atUTF16Offset: offset, rounding: .forward)
        guard endIndex > startIndex else {
            return nil
        }
        let startIndex = index(before: endIndex)
        return startIndex..<endIndex
    }
}
