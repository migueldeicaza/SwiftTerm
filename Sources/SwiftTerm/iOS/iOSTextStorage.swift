import Foundation
#if canImport(UIKit)
import UIKit

/*
    Convenience classes for the text input system.
    These are not part of the public API, but are used internally.
*/
class TextPosition: UITextPosition {
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
      let end = min(baseString.count, from.offset + maxOffset)
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
    let beginIndex = baseString.index(baseString.startIndex, offsetBy: startPosition.offset)
    let endIndex = baseString.index(beginIndex, offsetBy: endPosition.offset - startPosition.offset)
    return beginIndex..<endIndex
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
    _containsEnd = range.endPosition.offset == string.count
  }
}
#endif
