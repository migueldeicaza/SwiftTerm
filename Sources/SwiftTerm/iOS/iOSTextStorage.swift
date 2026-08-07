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

#if canImport(UIKit)
import UIKit

/*
    Convenience classes for the text input system.
    These are not part of the public API, but are used internally.
*/
class TextPosition: UITextPosition {
  // UITextInput communicates text ranges with NSRange-style UTF-16 offsets.
  let offset: Int
  
  init(offset: Int) {
    self.offset = offset
  }
}

extension TextPosition {
  override var description: String {
    return "\(offset)"
  }
}

class TextRange: UITextRange {
  let startPosition: TextPosition
  let endPosition: TextPosition
  
  init(from: TextPosition, to: TextPosition) {
    let start, end: TextPosition
    if from.offset < to.offset {
      start = from
      end = to
    } else {
      start = to
      end = from
    }
    self.startPosition = start
    self.endPosition = end
  }
  
  init(from: TextPosition, maxOffset: Int, in baseString: String) {
    if maxOffset >= 0 {
      self.startPosition = from
      let end = min(baseString.textInputUTF16Count, from.offset + maxOffset)
      self.endPosition = TextPosition(offset: end)
    } else {
      self.endPosition = from
      let begin = max(0, from.offset + maxOffset)
      self.startPosition = TextPosition(offset: begin)
    }
  }
  
  override var start: UITextPosition {
    return startPosition
  }
  
  override var end: UITextPosition {
    return endPosition
  }
  
  override var isEmpty: Bool {
    return startPosition.offset >= endPosition.offset
  }
  
  func fullRange(in baseString: String) -> Range<String.Index> {
    return baseString.textInputRange(startUTF16Offset: startPosition.offset, endUTF16Offset: endPosition.offset)
  }
  
  var length: Int {
    return endPosition.offset - startPosition.offset
  }
}

extension TextRange {
  override var description: String {
    return "[\(startPosition.offset)..<\(endPosition.offset)]"
  }
}

class TextSelectionRect: UITextSelectionRect {
  let _rect: CGRect
  let _containsStart: Bool
  let _containsEnd: Bool
  
  override var writingDirection: NSWritingDirection {
    return .leftToRight
  }
  
  override var isVertical: Bool {
    return false
  }
  
  override var rect: CGRect {
    return _rect
  }
  
  override var containsStart: Bool {
    return _containsStart
  }
  
  override var containsEnd: Bool {
    return _containsEnd
  }

  init(rect: CGRect, range: TextRange, string: String) {
    _rect = rect
    _containsStart = range.startPosition.offset == 0
    _containsEnd = range.endPosition.offset == string.textInputUTF16Count
  }
}
#endif
