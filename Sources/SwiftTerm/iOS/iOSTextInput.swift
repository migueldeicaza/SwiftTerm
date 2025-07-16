//
//
//
// iOSTextInput.swift: code necessary to support UITextInput, almost everything
// is here, with the exception of `insertText` which is in iOSTerminalView.
//
// The system will invoke either methods in this file, or `insertText` and will
// modify the markedText property during input to reflect the state of the data
// that needs to be removed or wiped.
//
// 1. First, regular typing, that should work.
//
// Input systems:
// 1. With a keyboard input system that supports composed input (like Chinese,
//    Simplified Pinyin), try typing "d", and then it should show a bar of
//    completions, and once selected, it should insert the full result.
// 2. With the above, attempt entering "dddd" and select the first instance,
//    it should insert "点点滴滴"
// 3. Bonus points, try the other Chinese input methods (they differ in the
//    way the data is entered).
//
// Dictation:
// 1. Enable dictation in the app, and then say the word "Hello world", and
//    then tap the microphone again.
// 2. The above should show "Hello world", with no spaces before it (a common
//    bug I fought when inserText was not tracking the markedText region was
//    that it would insert 11 spaces instead - if you get this, this is a
//    sign that the logic for the marking is wrong).
// 3. Dictate "Hello world" once, and then "Hello world" again, it should work,
//    if not, it is possible that the internal state of the selection has gone
//    out of sync again with the dictation system.
//
// Bonus tests, but these should just be straight forward:
// 1. Inserting an emoji from the keyboard emoji should work
// 2. Inserting arabic characters, pick "م" and then "ا" should render "ما"

//
// Ideas:
//   setMarkedText could show an overlay of the text being composed, so that
//   there is a visual cue of what is going on for foreign language input users
//
//  Created by Miguel de Icaza on 1/28/21.
//

//
// Observations 2025-05-27 GAR:
// 1. Dictation was not working. Seems that root cause we that the textInputStorage was being cleared
//    when the dictation was in progress and it could not update its hypothesis. Furthermore
//    the replace function was not sending changes to the terminal. This prevented the user
//    from seeing the incremental updates.
// 2. The dictation seems to always invoke insertText with an empty string and a space before it calls
//    insertDictationResult. This is not ideal, first sentences will always have a space before them. This
//    sequence can be detected in the terminal and handled as desired.
//

#if os(iOS) || os(visionOS)
import Foundation
import UIKit
import CoreText
import CoreGraphics

/// UITextInput Log capability
internal func uitiLog (_ message: String) {
    //print (message)
}

extension TerminalView: UITextInput {    
    func trace (function: String = #function)  {
        uitiLog ("TRACE: \(function)")
    }

    public func text(in range: UITextRange) -> String? {
        guard let r = range as? TextRange else { return nil }

        if r.isEmpty {
            return nil
        } else {
            return String (textInputStorage[r.fullRange(in: textInputStorage)])
        }        
    }
    
    public func replace(_ range: UITextRange, withText text: String) {
        guard let r = range as? TextRange else { return }

        guard _markedTextRange == nil else { return }
        uitiLog ("replace(range:\(r), withText:\"\(text)\") inputTextStorage:\"\(textInputStorage)\" markedTextRange:\(_markedTextRange?.description ?? "nil") selectedTextRange:\(_selectedTextRange.description)")

        // Send the edits to the terminal
        // Delete the old by sending as many backspaces as needed
        let oldText = textInputStorage [r.fullRange(in: textInputStorage)]
        let backspaces = oldText.count
        for _ in 0..<backspaces {
            self.send ([0x7f])
        }
        self.send (txt: text)

        let insertionIndex = r.startPosition.offset
        textInputStorage.replaceSubrange(r.fullRange(in: textInputStorage), with: text)
        if r.endPosition.offset <= _selectedTextRange.startPosition.offset {
            let selectionOffset = _selectedTextRange.startPosition.offset - insertionIndex
            let newSelectionOffset = selectionOffset - r.length + text.count
            let newSelectionIndex = newSelectionOffset + insertionIndex
            _selectedTextRange = TextRange(from: TextPosition(offset:newSelectionIndex), 
                                            to: TextPosition(offset: newSelectionIndex + _selectedTextRange.length))
        } else if r.startPosition.offset >= _selectedTextRange.endPosition.offset {
            // NOOP
        } else {
            let insertionEndPosition = TextPosition(offset:insertionIndex + text.count)            
            _selectedTextRange = TextRange(from: insertionEndPosition,  to: insertionEndPosition)
        }
    }

    /*
        If the text range has a length, it indicates the currently selected text. 
        If it has zero length, it indicates the caret (insertion point). 
        If the text-range object is nil, it indicates that there is no current selection.
    */
    public var selectedTextRange: UITextRange? {
        get {
            return _selectedTextRange
        }
        set {
            let nv = newValue as! TextRange
            _selectedTextRange = nv
            uitiLog ("selectedTextRange -> \(_selectedTextRange)")
        }
    }
    
    /*
        If there is no marked text, the value of the property is nil. 
        Marked text is provisionally inserted text that requires user confirmation; it occurs in multistage text input. 
        The current selection, which can be a caret or an extended range, always occurs within the marked text.
    */
    public var markedTextRange: UITextRange? {
        get {
            return _markedTextRange
        }
        set {
            _markedTextRange = newValue as? TextRange
            uitiLog("markedTextRange -> \(_markedTextRange)")
        }
    }
    
    public var markedTextStyle: [NSAttributedString.Key: Any]? {
        get {
            return _markedTextStyle
        }
        set {
            _markedTextStyle = newValue
        }
    }

    public func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        uitiLog("setMarkedText(\(markedText ?? "nil"), selectedRange:\(selectedRange)) textInputStorage:\"\(String(textInputStorage))\" count: \(textInputStorage.count) marked:\(_markedTextRange?.description ?? "nil") selected:\(_selectedTextRange.description)")

        let rangeToReplace = _markedTextRange ?? _selectedTextRange
        let rangeStartPosition = rangeToReplace.startPosition

        if let newText = markedText {
            textInputStorage.replaceSubrange(rangeToReplace.fullRange(in: textInputStorage), with: newText)
            // Figure out the new selection range
            let rangeStartIndex = rangeStartPosition.offset
            let newTextRange = Range(selectedRange, in: newText)!
            let newTextRangeOffset = newText.distance(from: newText.startIndex, to: newTextRange.lowerBound)
            let newTextRangeLength = newText.distance(from: newTextRange.lowerBound, to: newTextRange.upperBound)

            let selectionStartIndex = rangeStartIndex + newTextRangeOffset
            _markedTextRange = TextRange(from: rangeStartPosition, maxOffset: newText.count, in: textInputStorage) 
            _selectedTextRange = TextRange(from: TextPosition(offset: selectionStartIndex), 
                                           to: TextPosition(offset: selectionStartIndex + newTextRangeLength))
        } else {
            textInputStorage.removeSubrange(rangeToReplace.fullRange(in: textInputStorage))
            _markedTextRange = nil
            _selectedTextRange = TextRange(from: rangeStartPosition, to: rangeStartPosition)
        }        
    }

    func resetInputBuffer (_ loc: String = #function)
    {
        uitiLog("resetInputBuffer()")
        inputDelegate?.selectionWillChange(self)
        textInputStorage = ""
        _selectedTextRange = TextRange (from: TextPosition(offset: 0), to: TextPosition(offset: 0))
        _markedTextRange = nil
        inputDelegate?.selectionDidChange(self)
    }
    
    public func unmarkText() {
        uitiLog("unmarkText() textInputStorage:\"\(String(textInputStorage))\" count:\(textInputStorage.count) marked:\(_markedTextRange?.description ?? "nil") selected:\(_selectedTextRange.description)")        
        if let previouslyMarkedRange = _markedTextRange {
            let rangeEndPosition = previouslyMarkedRange.endPosition
            _selectedTextRange = TextRange(from: rangeEndPosition, to: rangeEndPosition)
            _markedTextRange = nil
        }        
    }
    
    public var beginningOfDocument: UITextPosition {
        return TextPosition(offset: 0)
    }
    
    public var endOfDocument: UITextPosition {
        return TextPosition(offset: textInputStorage.count)
    }
    
    public func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? TextPosition, let to = toPosition as? TextPosition else { return nil }
        return TextRange(from: from, to: to)
    }
    
    public func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let from = position as? TextPosition else { return nil }
        let newOffset = max(min(from.offset + offset, textInputStorage.count), 0)
        return TextPosition(offset: newOffset)
    }
    
    public func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        return self.position(from: position, offset: offset)
    }
    
    public func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard let from = position as? TextPosition, let to = other as? TextPosition else { return .orderedDescending }
        if from.offset < to.offset {
            return .orderedAscending
        } else if from.offset > to.offset {
            return .orderedDescending
        } else {
            return .orderedSame
        }
    }
    
    public func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard let from = from as? TextPosition, let to = toPosition as? TextPosition else { return 0 }
        return to.offset - from.offset
    }
            
    public func firstRect(for range: UITextRange) -> CGRect {
        return bounds
    }
    
    public func caretRect(for position: UITextPosition) -> CGRect {
        return bounds
    }
    
    public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        guard let r = range as? TextRange else { return [] }
        return [TextSelectionRect(rect: bounds, range: r, string: textInputStorage)]
    }
    
    // These can be exercised by the hold-spacebar
    public func closestPosition(to point: CGPoint) -> UITextPosition? {
        // return text position where the cursor is located based on the current selection
        let selection = _selectedTextRange
            return selection.startPosition
    }
    
    public func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        guard let r = range as? TextRange else { return nil }
        return r.startPosition
    }
    
    public func characterRange(at point: CGPoint) -> UITextRange? {
        return TextRange(from: TextPosition(offset: 0), to: TextPosition(offset: textInputStorage.count))
    }

    public func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        return range.end
    }

    public func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let p = position as? TextPosition else { return nil }
        return TextRange(from: p, to: TextPosition(offset: textInputStorage.count))
    }
    
    public func position(within range: UITextRange, atCharacterOffset offset: Int) -> UITextPosition? {
        guard let r = range as? TextRange else { return nil }
        let endOffset = r.startPosition.offset + offset
        if endOffset > r.endPosition.offset {
            return nil
        }
        return TextPosition(offset: endOffset)
    }
    
    public func characterOffset(of position: UITextPosition, within range: UITextRange) -> Int {
        guard let r = range as? TextRange, let p = position as? TextPosition else { return 0 }
        return p.offset - r.startPosition.offset
    }
    
    public func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        return .leftToRight
    }
    
    public func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {
        // do nothing
    }

    public func dictationRecordingDidEnd() {
        uitiLog("dictationRecordingDidEnd() textInputStorage:\"\(String(textInputStorage))\" count:\(textInputStorage.count) marked:\(_markedTextRange?.description ?? "nil") selected:\(_selectedTextRange.description)")
    }
    
    public func dictationRecognitionFailed() {
        uitiLog("dictationRecognitionFailed() textInputStorage:\"\(String(textInputStorage))\" count:\(textInputStorage.count) marked:\(_markedTextRange?.description ?? "nil") selected:\(_selectedTextRange.description)")
    }
    
    // MARK: - Dictation Placeholder Support
    
    public var insertDictationResultPlaceholder: Any {
        return "[DICTATION]"
    }
        
    public func removeDictationResultPlaceholder(_ placeholder: Any, willInsertResult: Bool) {
        uitiLog("removeDictationResultPlaceholder placeholder: \(placeholder), willInsertResult: \(willInsertResult)")
    }
    
    public func insertDictationResult(_ dictationResult: [UIDictationPhrase]) {
        uitiLog("insertDictationResult() phrases: \(dictationResult)")
        uitiLog("textInputStorage:\"\(String(textInputStorage))\" count:\(textInputStorage.count) marked:\(_markedTextRange?.description ?? "nil") selected:\(_selectedTextRange.description)")
        
        // Combine all phrases into a single string
        let combinedText = dictationResult.map { $0.text }.joined()

        if combinedText.count > 0 {
            insertText(combinedText)
        }
    }
    
    /*
        Software trackpad when user long press the spacebar.
    */
    public func beginFloatingCursor(at point: CGPoint)
    {
        lastFloatingCursorLocation = point
    }

    public func updateFloatingCursor(at point: CGPoint)
    {
        //uitiLog("updateFloatingCursor(at: \(point)) lastFloatingCursorLocation: \(lastFloatingCursorLocation)")
        guard let lastPosition = lastFloatingCursorLocation else {
            return
        }
        let deltax = lastPosition.x - point.x
        
        // Defines how sensitive the cursor is to "trackpad" movements. 
        // 5 is a happy medium between fast moving and precise enough.
        if abs(deltax) > 5 {
            var data: [UInt8]
            if deltax > 0 {
                data = terminal.applicationCursor ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal
                // Update the carret to the new position so that deleteBackward will delete the correct character
                let newOffset = max(_selectedTextRange.startPosition.offset - 1, 0)
                selectedTextRange = TextRange(from: TextPosition(offset: newOffset), 
                    to: TextPosition(offset: newOffset))
            } else {
                data = terminal.applicationCursor ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal
                // Update the carret to the new position so that deleteForward will delete the correct character
                let newOffset = min(_selectedTextRange.startPosition.offset + 1, textInputStorage.count)
                selectedTextRange = TextRange(from: TextPosition(offset: newOffset), 
                    to: TextPosition(offset: newOffset))
            }
            send (data)
            lastFloatingCursorLocation = point
        }

        if terminal.isCurrentBufferAlternate {
            let deltay = lastPosition.y - point.y

            var data: [UInt8]
            if abs (deltay) > 2 {
                if deltay > 0 {
                    data = terminal.applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal
                } else {
                    data = terminal.applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal
                }
                send (data)
                lastFloatingCursorLocation = point
            }
        }
    }
    
    public func endFloatingCursor()
    {
        lastFloatingCursorLocation = nil
    }
}

#endif
