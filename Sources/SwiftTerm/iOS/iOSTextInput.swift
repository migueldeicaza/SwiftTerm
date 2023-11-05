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
        guard let r = range as? xTextRange else { return "" }
        
        if textInputStorage.count >= max (r._start, r._end) {
            let res = String (textInputStorage [r._start..<r._end])
            
            // This is necessary, because something is going out of sync
            //let res = String (textInputStorage [max(r._start,textInputStorage.count-1)..<min(r._end, textInputStorage.count)])
            uitiLog ("text(start=\(r._start) end=\(r._end)) => \"\(res)\"")
            return res
        } else {
            if #available(iOS 14.0, *) {
                log.critical("Attempt to access [\(r._start)..<\(r.end) on a string with \(self.textInputStorage.count)")
            } else {
                //print ("Attempt to access [\(r._start)..<\(r.end) on a string with \(textInputStorage.count)")
            }
            return ""
        }
    }
    
    func replace (_ buffer: [Character], start: Int, end: Int, withText text: String) -> [Character] {
        let s = start >= buffer.count ? max (0, buffer.count-1) : start
        
        let first = buffer[0..<s]
        let second = end >= buffer.count ? buffer [0..<0] : buffer [end...]
        
        return Array (first + text + second)
    }
    
    public func replace(_ range: UITextRange, withText text: String) {
        let r = range as! xTextRange
        uitiLog ("replace (\(r._start)..\(r._end) with: \"\(text)\") currentSize=\(textInputStorage.count)")
        textInputStorage = replace (textInputStorage, start: r._start, end: r._end, withText: text)
        
        // This is necessary, because I am getting an index that was created a long time before, not sure why
        // serial 21 vs 31
        let idx = min (textInputStorage.count, r._start + text.count)
        _selectedTextRange = xTextRange(idx, idx)
    }

    public var selectedTextRange: UITextRange? {
        get {
            uitiLog ("selectedTextRange -> [\(_selectedTextRange._start)..<\(_selectedTextRange._end)]")
            return _selectedTextRange
        }
        set(newValue) {
            let nv = newValue as! xTextRange
            _selectedTextRange = nv
        }
    }
    
    public var markedTextRange: UITextRange? {
        get {
            return _markedTextRange
        }
        set {
            _markedTextRange = newValue as? xTextRange
        }
    }
    
    public var markedTextStyle: [NSAttributedString.Key : Any]? {
        get {
            return nil
        }
        set(markedTextStyle) {
            //
        }
    }

    public func setMarkedText(_ string: String?, selectedRange: NSRange) {
        
        // setMarkedText operation takes effect on current focus point (marked or selected)
        uitiLog("setMarkedText: \(string as Any), selectedRange: \(selectedRange)")
      
        // after marked text is updated, old selection or markded range is replaced,
        // new marked range is always updated
        // and new selection is always changed to a new range with in
      
        uitiLog ("/ SET MARKED BEGIN ")
        uitiLog ("| _markedTextRange -> \(_markedTextRange?.debugDescription ?? "nil")")
        uitiLog ("| selectedRange -> \(selectedRange)")
        uitiLog ("| _selectedTextRange -> \(_selectedTextRange)")
        uitiLog ("\\-------------")
       
        let rangeToReplace = _markedTextRange ?? _selectedTextRange 
        let rangeStartPosition = rangeToReplace._start
        if let newString = string {
            textInputStorage = replace(textInputStorage, start: rangeToReplace._start, end: rangeToReplace._end, withText: newString)
            _markedTextRange = xTextRange (rangeStartPosition, rangeStartPosition+newString.count)
            
            let rangeStartIndex = rangeStartPosition
            let selectionStartIndex = rangeStartIndex + selectedRange.lowerBound
            _selectedTextRange = xTextRange(selectionStartIndex, selectionStartIndex + selectedRange.length)
            _markedTextRange = xTextRange(rangeStartPosition, rangeStartPosition + newString.count)
        } else {
            textInputStorage = replace(textInputStorage, start: rangeToReplace._start, end: rangeToReplace._end, withText: "")
            _markedTextRange = nil
            _selectedTextRange = xTextRange (rangeStartPosition, rangeStartPosition)
        }
    }

    func resetInputBuffer (_ loc: String = #function)
    {
        inputDelegate?.selectionWillChange(self)
        textInputStorage = []
        _selectedTextRange = xTextRange (0, 0)
        _markedTextRange = nil
        inputDelegate?.selectionDidChange(self)
    }
    
    public func unmarkText() {
        if let previouslyMarkedRange = _markedTextRange {
            let rangeEndPosition = previouslyMarkedRange._end
            _selectedTextRange = xTextRange(rangeEndPosition, rangeEndPosition)
         
            // Not clear when I can then flush the contents of textInputStorage
            send (txt: String (textInputStorage))
            resetInputBuffer ()
        }
    }
    
    public var beginningOfDocument: UITextPosition {
        return xTextPosition(textInputStorage.startIndex)
    }
    
    public var endOfDocument: UITextPosition {
        return xTextPosition(textInputStorage.endIndex)
    }
    
    public func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        let f = fromPosition as! xTextPosition
        let t = toPosition as! xTextPosition
        uitiLog("[Geometry] form range [\(f.start) ..< \(t.start)]")
        return xTextRange (f.start, t.start)
    }
    
    public func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        let p = (position as! xTextPosition).start
        let newOffset = max(min(p + offset, textInputStorage.count), 0)
        uitiLog("[Geometry] position (from position: \(p), offset: \(offset)) -> \(newOffset)")
        return xTextPosition (newOffset)
    }
    
    public func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        trace()
        return nil
    }
    
    public func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        if let first = position as? xTextPosition,
           let second = other as? xTextPosition {
            if first.start < second.start {
                return .orderedAscending
            } else if first.start == second.start {
                return .orderedSame
            }
        }
        return .orderedDescending
    }
    
    public func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        let f = (from as! xTextPosition).start
        let t = (toPosition as! xTextPosition).start

        let d = textInputStorage.distance(from: f, to: t)
        uitiLog("[Geometry] form offset to=\(t) - from:\(f)")
        return d
    }
    
    public func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        trace()
        return nil
    }
    
    public func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        trace()
        return nil
    }
    
    public func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        return .leftToRight
    }
    
    public func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {
        // do nothing
    }
    
    public func firstRect(for range: UITextRange) -> CGRect {
        //print ("Text, firstRect (range)")
        return bounds
    }
    
    public func caretRect(for position: UITextPosition) -> CGRect {
        // TODO
        //print ("Text, caretRect (range)")
        return bounds
    }
    
    public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        // TODO
        //print ("Text, selectionRect (range)")
        return []
    }
    
    // These can be exercised by the hold-spacebar
    public func closestPosition(to point: CGPoint) -> UITextPosition? {
        return xTextPosition(0)
    }
    
    public func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        return xTextPosition(0)
    }
    
    public func characterRange(at point: CGPoint) -> UITextRange? {
        return xTextRange(0, 0)
    }
    
    public func dictationRecordingDidEnd() {
        uitiLog("\(textInputStorage), dictation recording end")
    }
    
    public func dictationRecognitionFailed() {
        uitiLog("\(textInputStorage), dictation failed")
    }
    
    public func insertDictationResult(_ dictationResult: [UIDictationPhrase]) {
        uitiLog("\(textInputStorage), insertDictationResult: \(dictationResult)")
    }
    
    // This method is invoked from `insertText` with the provided text, and
    // it should compute based on that input text and the current marked/selection
    // what should be inserted
    func applyTextToInput (_ text: String) -> String {
        var sendData: String = ""
        
        if let rangeToReplace = _markedTextRange {
            let rangeStartIndex = rangeToReplace._start
            let tmp = "insertText (\"\(text)\" into \"\(String(textInputStorage))\") rangeToReplace=[\(rangeToReplace._start)..<\(rangeToReplace._end)]"
            textInputStorage = replace (textInputStorage, start: rangeToReplace._start, end: rangeToReplace._end, withText: text)
            
            uitiLog ("\(tmp) -> \(String(textInputStorage))")
            _markedTextRange = nil
            let pos = rangeStartIndex + text.count
            
            _selectedTextRange = xTextRange(pos, pos)
            sendData = ""
        } else if _selectedTextRange.length > 0 {
            let rangeToReplace = _selectedTextRange
            let rangeStartIndex = rangeToReplace._start
            let tmp = "insertText (\"\(text)\" into \"\(String(textInputStorage))\") rangeToReplace=[\(rangeToReplace._start)..<\(rangeToReplace._end)]"
            textInputStorage = replace (textInputStorage, start: rangeToReplace._start, end: rangeToReplace._end, withText: text)
            
            uitiLog ("\(tmp) -> \(String(textInputStorage))")
            _markedTextRange = nil
            let pos = rangeStartIndex + text.count
            
            _selectedTextRange = xTextRange(pos, pos)
            sendData = ""
        } else {
            if textInputStorage.count != 0 {
                sendData = String (textInputStorage)
            } else {
                sendData = text
            }
        }
        return sendData
    }
    
    public func beginFloatingCursor(at point: CGPoint)
    {
        lastFloatingCursorLocation = point
    }
    public func updateFloatingCursor(at point: CGPoint)
    {
        guard let lastPosition = lastFloatingCursorLocation else {
            return
        }
        lastFloatingCursorLocation = point
        let deltax = lastPosition.x - point.x
        
        
        if abs (deltax) > 2 {
            var data: [UInt8]
            if deltax > 0 {
                data = terminal.applicationCursor ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal
            } else {
                data = terminal.applicationCursor ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal
            }
            send (data)
        }
        if terminal.buffers.isAlternateBuffer {
            let deltay = lastPosition.y - point.y

            var data: [UInt8]
            if abs (deltay) > 2 {
                if deltay > 0 {
                    data = terminal.applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal
                } else {
                    data = terminal.applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal
                }
                send (data)
            }
        }
    }
    
    public func endFloatingCursor()
    {
        lastFloatingCursorLocation = nil
    }
}

class xTextPosition: UITextPosition {
    var start: Int
    
    init (_ start: Int) {
        if start < 0 {
            if #available(iOS 14.0, *) {
                log.critical("xTextPosition created with start=\(start), resetting to 0")
            } else {
                print ("xTextPosition created with start=\(start), resetting to 0")
            }
            self.start = 0
            return
        }
        self.start = start
    }
    
    public override var debugDescription: String {
        get {
            return "Pos=\(start)"
        }
    }
}

var serial: Int = 0
class xTextRange: UITextRange {
    var _start, _end: Int
    var fun: String
    var line: Int
    var s: Int
    
    public init (_ start: Int, _ end: Int, _ fun: String = #function, _ line: Int = #line) {
        self.fun = fun
        self.line = line
        self.s = serial
        serial += 1
        if end < start {
            if #available(iOS 14.0, *) {
                log.critical("xTextRange created with end=\(end) < start=\(start), resetting")
            } else {
                print ("xTextRange created with end=\(end) < start=\(start), resetting")
            }
            self._start = 0
            self._end = 0
        } else {
            self._start = start
            self._end = end
        }
    }
    
    override var start: UITextPosition {
        xTextPosition(_end)
    }
    override var end: UITextPosition {
        xTextPosition (_end)
    }
    override var isEmpty: Bool {
        _start >= _end
    }
    
    var length: Int {
      return _end - _start
    }

    public override var debugDescription: String {
        get {
            return "Range(start=\(start), end=\(end))"
        }
    }
}
#endif
