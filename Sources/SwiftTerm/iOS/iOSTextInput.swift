//
//  File.swift
//
// Classes to support UITextInput text protocol, which drives support
// for input methods, and dictation on iOS
//
//
//  Created by Miguel de Icaza on 1/28/21.
//

#if os(iOS)
import Foundation
import UIKit
import CoreText
import CoreGraphics

#if true

var storage: [Character] = []
var sel: xTextRange?

class xTextPosition: UITextPosition {
    var start: Int
    
    init (_ start: Int) {
        if start < 0 {
            abort()
        }
        self.start = start
    }
    public override var debugDescription: String {
        get {
            return "Pos=\(start)"
        }
    }
}

class xTextRange: UITextRange {
    var _start, _end: Int
    
    public init (_ start: Int, _ end: Int) {
        if end < start {
            abort()
        }
        self._start = start
        self._end = end
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
    
    public override var debugDescription: String {
        get {
            return "Range(start=\(start), end=\(end))"
        }
    }
}

extension TerminalView: UITextInput {
    
    func pabort (_ msg: String = #function)
    {
        print (msg)
        abort ()
    }

    func trace (function: String = #function)  {
        print ("TRACE: \(function)")
    }

    public func text(in range: UITextRange) -> String? {
        let r = range as! xTextRange
        let res = String (storage [r._start..<r._end])
        print ("text(start=\(r._start) end=\(r._end)) => \"\(res)\"")
        return res
    }
    
    func replace (_ buffer: [Character], start: Int, end: Int, withText text: String) -> [Character] {
        let first = buffer[0..<start]
        let second = end >= buffer.count ? buffer [0..<0] : buffer [end...]
        
        return Array (first + text + second)
    }
    
    public func replace(_ range: UITextRange, withText text: String) {
        let r = range as! xTextRange
        print ("replace (\(r._start)..\(r._end) with: \"\(text)\")")

        storage = replace (storage, start: r._start, end: r._end, withText: text)
        let idx = r._start + text.count
        sel = xTextRange(idx, idx)
    }
    
    public var selectedTextRange: UITextRange? {
        get {
            if sel == nil {
                sel = xTextRange (storage.endIndex, storage.endIndex)
            }
            print ("selectedTextRange -> \(sel)")
            return sel
        }
        set(newValue) {
            let nv = newValue as! xTextRange
            sel = nv
    
        }
    }
    
    public var markedTextRange: UITextRange? {
        get {
            return _markedTextRange
        }
        set {
            if newValue == nil {
                abort ()
                print ("Commit the text")
            }
            _markedTextRange = newValue as? xTextRange
        }
    }
    
    public var markedTextStyle: [NSAttributedString.Key : Any]? {
        get {
            abort()
        }
        set(markedTextStyle) {
            pabort()
        }
    }
    
    //        if let mtr = _markedTextRange {
    //            print ("TODO: replaceCahracterInRange (markedTextRange) with the text")
    //            let n = countDiff (mtr)
    //            let ch: UInt8 = backspaceSendsControlH ? 8 : 0x7f
    //            //send(Array<UInt8>.init(repeating: ch , count: n))
    //            send(txt: text)
    //            mtr._end = TerminalTextPosition (advance (position: mtr._start.pos, offset: text.count))
    //        } else if selectedRange.length > 0 {
    //            // There is no marked range, but there is a selected range
    //            // so replace text storage at selected range and updated markedTextRange
    //            print ("SELECTION: I do not think we should attempt to support updating the selection with mark")
    //            //selection.active = false
    //            send(txt: text)
    //            let start = Position(col: buffer.x, row: buffer.y)
    //            _markedTextRange = makeRange(start: start, end: advance (position: start, offset: markedText?.count ?? 0))
    //        } else {
    //            //selection.active = false
    //            send (txt: text)
    //            let start = Position(col: buffer.x, row: buffer.y)
    //            _markedTextRange = makeRange(start: start, end: advance (position: start, offset: markedText?.count ?? 0))
    
    public func setMarkedText(_ string: String?, selectedRange: NSRange) {
        
        // setMarkedText operation takes effect on current focus point (marked or selected)
        print("setMarkedText: \(string as Any), selectedRange: \(selectedRange)")
      
        // after marked text is updated, old selection or markded range is replaced,
        // new marked range is always updated
        // and new selection is always changed to a new range with in
      
        print ("/ SET MARKED BEGIN ")
        print ("| _markedTextRange -> \(_markedTextRange)")
        print ("| selectedRange -> \(selectedRange)")
        print ("| _selectedTextRange -> \(_selectedTextRange)")
        print ("\\-------------")
       
        if let rangeToReplace = _markedTextRange ?? _selectedTextRange {
            let rangeStartPosition = rangeToReplace._start
            if let newString = string {
                storage = replace(storage, start: rangeToReplace._start, end: rangeToReplace._end, withText: newString)
                _markedTextRange = xTextRange (rangeStartPosition, rangeStartPosition+newString.count)
                
                let rangeStartIndex = rangeStartPosition
                let selectionStartIndex = rangeStartIndex + selectedRange.lowerBound
                _selectedTextRange = xTextRange(selectionStartIndex, selectionStartIndex + selectedRange.length)
                _markedTextRange = xTextRange(rangeStartPosition, rangeStartPosition + newString.count)
                //send (txt: newString)
            } else {
                storage = replace(storage, start: rangeToReplace._start, end: rangeToReplace._end, withText: "")
                _markedTextRange = nil
                _selectedTextRange = xTextRange (rangeStartPosition, rangeStartPosition)

            }
        }
    }
    
    public func unmarkText() {
        if let previouslyMarkedRange = _markedTextRange {
            let rangeEndPosition = previouslyMarkedRange._end
            _selectedTextRange = xTextRange(rangeEndPosition, rangeEndPosition)
            _markedTextRange = nil
        }
    }
    
    public var beginningOfDocument: UITextPosition {
        return xTextPosition(storage.startIndex)
    }
    
    public var endOfDocument: UITextPosition {
        return xTextPosition(storage.endIndex)
    }
    
    public func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        let f = fromPosition as! xTextPosition
        let t = toPosition as! xTextPosition
        
        return xTextRange (f.start, t.start)
    }
    
    public func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        let p = (position as! xTextPosition).start
        let new = p + offset
        if offset < 0 {
            return xTextPosition (0)
        } else if offset >= storage.count {
            return xTextPosition (storage.count)
        }
        
        return xTextPosition (new)
    }
    
    public func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        abort()
    }
    
    public func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let first = position as! xTextPosition
        let second = other as! xTextPosition
        if first.start < second.start {
            return .orderedAscending
        } else if first.start == second.start {
            return .orderedSame
        }
        return .orderedDescending
    }
    
    public func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        let f = (from as! xTextPosition).start
        let t = (toPosition as! xTextPosition).start

        let d = storage.distance(from: f, to: t)
        return d
    }
    
    public func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        abort()
    }
    
    public func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        abort()
    }
    
    public func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        return .leftToRight
    }
    
    public func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {
        // do nothing
    }
    
    public func firstRect(for range: UITextRange) -> CGRect {
        abort()
    }
    
    public func caretRect(for position: UITextPosition) -> CGRect {
        // TODO
        return bounds
    }
    
    public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        // TODO
        return []
    }
    
    public func closestPosition(to point: CGPoint) -> UITextPosition? {
        abort()
    }
    
    public func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        abort()
    }
    
    public func characterRange(at point: CGPoint) -> UITextRange? {
        abort()
    }
    
//    public func insertDictationResult(_ dictationResult: [UIDictationPhrase])
//    {
//        for x in dictationResult {
//            print ("Dictation: \(x.text)")
//        }
//    }

}
//// This extension implements the support for UITextInput
//extension TerminalView : UITextInput {
//
//    func pabort (_ msg: String)
//    {
//        print (msg)
//        abort ()
//    }
//
//    func trace (function: String = #function)  {
//        print ("TRACE: \(function)")
//    }
//
//    public func text(in range: UITextRange) -> String? {
//        guard let termRange = range as? TerminalTextRange,
//              let start = (termRange.start as? TerminalTextPosition)?.pos,
//              let end = (termRange.end as? TerminalTextPosition)?.pos else {
//            print ("WAERNING: text(in: range) unknown range passed")
//            return nil
//        }
//
//        let text = terminal.getText(start: start, end: end)
//
//        print ("text(in range: \(start)-\(end)) -> \"\(text)\"")
//        return text
//    }
//
//    public func replace(_ range: UITextRange, withText text: String) {
//        trace ()
//        guard let r = range as? TerminalTextRange else {
//            pabort ("replace: Called with a non TerminalTextRange")
//            return
//        }
//        print ("replace (\(r._start.pos)-\(r._end.pos), withText: >\(text)<)")
//        if text == "" {
//            return
//        }
//        send (txt: text)
//        print ("REPLACE: found a replacement with body: \(text)")
//    }
//
//    public func shouldChangeText(in range: UITextRange,
//                   replacementText text: String) -> Bool
//    {
//        print ("Should change called with \(text)")
//        return true
//    }
//
//    func makeRange (start: Position, end: Position) -> TerminalTextRange {
//        return TerminalTextRange (start: TerminalTextPosition (start), end: TerminalTextPosition (end))
//    }
//
//
//    class Demo: NSObject {
//
//    }
//    public var insertDictationResultPlaceholder: Any {
//        get {
//            print ("Starting")
//            return Demo ()
//        }
//    }
//
//    public func frame(forDictationResultPlaceholder placeholder: Any) -> CGRect
//    {
//        return bounds
//    }
//
//    public func insertDictationResult(_ dictationResult: [UIDictationPhrase])
//    {
//        for x in dictationResult {
//            print ("Dictation: \(x.text)")
//        }
//    }
//
//
//
//    public var selectedTextRange: UITextRange? {
//        get {
////            if selection.active && selection.hasSelectionRange {
////                print ("selectedTextRange (selection.active && selection.hasSelectionRange: \(selection.start)-\(selection.end)")
////                return makeRange(start: selection.start, end: selection.end)
////            }
//            let b = terminal.buffer
//            let cursor = Position(col: b.x, row: b.y)
//            print ("selectedTextRange: making range on cursor position \(cursor)")
//            let ret = makeRange(start: cursor, end: cursor)
//            return ret
//        }
//        set {
//            trace ()
//
//            if let newRange = newValue as? TerminalTextRange {
//                if let start = (newRange.start as? TerminalTextPosition),
//                    let end = (newRange.end as? TerminalTextPosition) {
//                    print ("SET -- SelectexTextRange to \(start.debugDescription) to \(end.debugDescription)")
//                    _selectedTextRange = newRange
//                    //selection.setSelection(start: start.pos, end: end.pos)
//                    return
//                }
//            }
//            print ("ALERT: setSelectedTextRange newValue was not a TerminalTextRange")
//            selection.active = false
//        }
//    }
//
//    // TODO: we should track the markedTextRange in a struct, not an NSObject, and just create here on demand
//    public var markedTextRange: UITextRange? {
//        get {
//            // trace ()
//            //print ("markedTextRange -> \(_markedTextRange)")
//            return _markedTextRange
//        }
//    }
//
//    public var markedTextStyle: [NSAttributedString.Key : Any]? {
//        get {
//            pabort ("PROTO: markedTextStyle")
//            return nil
//        }
//        set {
//            pabort ("PROTO: set markedTextStyle")
//        }
//    }
//
//    func countDiff (_ range: TerminalTextRange) -> Int
//    {
//        let rdiff = range._end.pos.row - range._start.pos.row
//        let cdiff = range._end.pos.col - range._start.pos.col
//
//        return rdiff * terminal.cols + cdiff
//    }
//
//    func advance (position: Position, offset: Int) -> Position
//    {
//        let b = terminal.buffer
//        let p = position.row * b.cols + position.col + offset
//
//        var line = p / b.cols
//        var col = p % b.cols
//
//        if offset >= 0 {
//            if line != position.row {
//
//            }
//        } else {
//            if line != position.row {
//                line = position.row
//                col = 0
//            }
//            if col < 0 {
//                col = 0
//            }
//        }
//
//        // Wrap the line around
//        line = min (line, b.rows-1)
//        if col < 0 {
//            print ("hello")
//        }
//        print ("Returning advanced from \(position),offset=\(offset) to col=\(col),row=\(line)")
//        return Position(col: col, row: line)
//    }
//
//    public func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
//        let buffer = terminal.buffer
//        let text = markedText ?? ""
//        trace ()
//        print ("setMarkedText (\"\(markedText)\", selectedRange: \(selectedRange))")
//        if let mtr = _markedTextRange {
//            print ("TODO: replaceCahracterInRange (markedTextRange) with the text")
//            let n = countDiff (mtr)
//            let ch: UInt8 = backspaceSendsControlH ? 8 : 0x7f
//            //send(Array<UInt8>.init(repeating: ch , count: n))
//            send(txt: text)
//            mtr._end = TerminalTextPosition (advance (position: mtr._start.pos, offset: text.count))
//        } else if selectedRange.length > 0 {
//            // There is no marked range, but there is a selected range
//            // so replace text storage at selected range and updated markedTextRange
//            print ("SELECTION: I do not think we should attempt to support updating the selection with mark")
//            //selection.active = false
//            send(txt: text)
//            let start = Position(col: buffer.x, row: buffer.y)
//            _markedTextRange = makeRange(start: start, end: advance (position: start, offset: markedText?.count ?? 0))
//        } else {
//            //selection.active = false
//            send (txt: text)
//            let start = Position(col: buffer.x, row: buffer.y)
//            _markedTextRange = makeRange(start: start, end: advance (position: start, offset: markedText?.count ?? 0))
//        }
//    }
//
//    public func unmarkText() {
//        trace ()
//        _markedTextRange = nil
//    }
//
//    public var beginningOfDocument: UITextPosition {
//        get {
//            #if false
//            let b = terminal.buffer
//            print ("beggingOfDocument -> Position(col: \(b.x), row: \(b.y)) ")
//            return TerminalTextPosition(Position (col: b.x, row: b.y))
//            #else
//            let b = terminal.buffer
//            return TerminalTextPosition(Position (col: 0, row: b.y))
//            #endif
//
//        }
//    }
//
//    public var endOfDocument: UITextPosition {
//        get {
//            #if false
//            let b = terminal.buffer
//            print ("endOfDocument -> Position(col: \(b.x), row: \(b.y)) ")
//            return TerminalTextPosition(Position (col: terminal.cols-1, row: b.y))
//            #else
//            //print ("endOfDocument -> Position(col: \(terminal.cols-1), row: \(terminal.rows-1)) ")
//            let b = terminal.buffer
//            return TerminalTextPosition(Position (col: terminal.cols, row: b.y))
//            #endif
//        }
//    }
//
//    public func beginFloatingCursor(at: CGPoint) {
//        pabort ("oo")
//    }
//
//    public func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
//        guard let from = fromPosition as? TerminalTextPosition, let to = toPosition as? TerminalTextPosition else {
//            //pabort ("Debug this")
//            print ("textRange: WARNING, GOT INVALID VALUES")
//            return nil
//        }
//        print("[Geometry] form range [\(from.pos) ..< \(to.pos)]")
//        if Position.compare (from.pos, to.pos) == .before  {
//            return TerminalTextRange(start: from, end: to)
//        } else {
//            return TerminalTextRange(start: to, end: from)
//        }
//    }
//
//    public func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
//        //trace ()
//        guard let pos = position as? TerminalTextPosition else {
//            abort ()
//        }
//        //print ("position (from: \(pos.pos), offset: \(offset)")
//        let new = advance(position: pos.pos, offset: offset)
//        print ("position (from: \(pos.pos), offset: \(offset)) -> \(new)")
//        return TerminalTextPosition (new)
//        if new.row != pos.pos.row {
//            print ("ROW HACK: reporting out of bounds")
//            return nil
//        }
//        if new.col < 0 || new.col >= terminal.cols || new.row < 0 || new.row >= terminal.rows {
//            print ("position from position is out of bounds, new value is: \(new)")
//            return nil
//        }
//        return TerminalTextPosition (new)
//    }
//
//    public func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
//        trace ()
//        pabort ("PROTO: position2")
//        return nil
//    }
//
//    public func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
//        if let a = position as? TerminalTextPosition {
//            if let b = other as? TerminalTextPosition {
//                let str = "compare \(a.pos) with \(b.pos)"
//                switch Position.compare(a.pos, b.pos){
//                case .before:
//                    //print ("\(str) ascending")
//                    return .orderedAscending
//                case .after:
//                    //print ("\(str) descending")
//                    return .orderedDescending
//                case .equal:
//                    //print ("\(str) same")
//                    return .orderedSame
//                }
//            }
//        }
//        print ("COMPARE BAILING")
//        return .orderedSame
//    }
//
//    public func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
//        guard let start = from as? TerminalTextPosition, let end = toPosition as? TerminalTextPosition else {
//          fatalError()
//        }
//        let str = terminal.getText (start: start.pos, end: end.pos)
//        print ("Offset (from: \(start.pos), to: \(end.pos) -> \(str.utf16.count)")
//
//        return str.utf16.count
//    }
//
//    public func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
//        pabort ("PROTO: position3")
//        return nil
//    }
//
//    public func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
//        pabort ("PROTO: characterRnage")
//        return nil
//    }
//
//    public func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
//        return .leftToRight
//    }
//
//    public func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {
//        pabort ("PROTO: setBaseWritingDirection")
//
//    }
//
//    public func firstRect(for range: UITextRange) -> CGRect {
//        trace ()
//        guard let r = range as? TerminalTextRange else {
//            pabort ("firstRect (for range: UITextRange) received a non-TerminalTextRange")
//            return CGRect.zero
//        }
//        print ("TODO: firstRect (for Range) needs SCROLLSUPPORT + CORRECTREGION)")
//        return bounds
//    }
//
//    func posToPoint (_ pos: Position) -> CGPoint {
//        return CGPoint(x: CGFloat (pos.col) * cellDimension.width, y: CGFloat(pos.row) * cellDimension.height)
//    }
//
//    func cellSize () -> CGSize {
//        return CGSize (width: cellDimension.width, height: cellDimension.height)
//    }
//
//    public func caretRect(for position: UITextPosition) -> CGRect {
//        trace ()
//        guard let pos = position as? TerminalTextPosition  else {
//            abort ()
//        }
//
//        let rect = CGRect (origin: posToPoint(pos.pos), size: cellSize())
//        print ("caretRect for \(pos.pos) -> \(rect)")
//        return rect
//    }
//
//    // Trigger this by hitting the microphone
//    public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
//        trace ()
//        guard let myRange = range as? TerminalTextRange else {
//            //print ("FATAL/PROTO: selectionRects does not get a TerminalTextRange")
//
//            return []
//        }
//        var rets: [UITextSelectionRect] = []
//        let start = myRange._start.pos
//        let end = myRange._end.pos
//        if start.row == end.row {
//            rets.append (TerminalSelectionRect (
//                rect: CGRect(origin: posToPoint(start), size: cellSize()),
//                            range: myRange, string: text (in: range) ?? "", start: true, end: true))
//        } else {
//            print ("Need to handle split regions, create a start, middle and end")
//            abort ()
//        }
//        for x in rets {
//            print ("SlectionRets return: \(x)")
//        }
//        return rets
//    }
//
//    // Trigger this by long-pressing the space-bar
//    public func closestPosition(to point: CGPoint) -> UITextPosition? {
//        trace ()
//        let col = min (max (0, Int (point.x / cellDimension.width)), terminal.rows)
//        let row = min (max (0, Int (point.y / cellDimension.height)), terminal.cols)
//
//        // TODO: probably this should return a position offset by the scroll position
//        print ("closestPosition called for \(point)")
//        return TerminalTextPosition (Position (col: col, row: row))
//    }
//
//    public func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
//        pabort ("PROTO: closestPosition")
//        return nil
//    }
//
//    public func characterRange(at point: CGPoint) -> UITextRange? {
//        pabort ("PROTO: characterRange")
//        return nil
//    }
//}
#else

// This class is here just, so TerminalView will compile even when the
// support for UITextInput is disabled.
class DummyDel {
    func selectionWillChange (_ t: TerminalView) {}
    func selectionDidChange (_ t: TerminalView) {}
    static var global = DummyDel ()
}
extension TerminalView {
    public var inputDelegate: DummyDel {
        get {
            return DummyDel.global
        }
    }
}
#endif

// The text position is relative to the start of the buffer (buffer.yBase)
class TerminalTextPosition: UITextPosition {
    var pos: Position
    init (_ pos: Position)
    {
        self.pos = pos
    }
    
    public override var debugDescription: String {
        get {
            return "(col=\(pos.col),row=\(pos.row))"
        }
    }
}

class TerminalTextRange: UITextRange {
    var _start: TerminalTextPosition
    var _end: TerminalTextPosition
    
    init(start: TerminalTextPosition, end: TerminalTextPosition) {
        _start = start
        _end = end
    }
    
    override var start: UITextPosition { _start }
    override var end: UITextPosition { _end }
    override var isEmpty: Bool { _start == _end }
    
    public override var debugDescription: String {
        get {
            return "\(start)-\(end)"
        }
    }
}

class TerminalSelectionRect: UITextSelectionRect {
    var _rect: CGRect
    var _containsStart: Bool
    var _containsEnd: Bool
    
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

    init(rect: CGRect, range: TerminalTextRange, string: String, start: Bool, end: Bool) {
        _rect = rect
        
        print ("TerminalSelectionRect, THIS IS WRONG:")
        _containsStart = true
        _containsEnd = true
    }
}

// This code is currently not enabled, we are using a standard string tokenizer, see UITextInputStringTokenizer below
class TerminalInputTokenizer: NSObject, UITextInputTokenizer {
    func pabort (_ msg: String)
    {
        print (msg)
        abort()
    }
    func rangeEnclosingPosition(_ position: UITextPosition, with granularity: UITextGranularity, inDirection direction: UITextDirection) -> UITextRange? {
        pabort ("PROTO: MIT/Range")

        return nil
    }

    func isPosition(_ position: UITextPosition, atBoundary: UITextGranularity, inDirection: UITextDirection) -> Bool {
        pabort ("PROTO: MIT/offset")
        return false
    }

    func position(from position: UITextPosition, toBoundary granularity: UITextGranularity, inDirection direction: UITextDirection) -> UITextPosition? {
        pabort ("PROTO: MIT/position1")
        return nil
    }

    func isPosition(_ position: UITextPosition, withinTextUnit granularity: UITextGranularity, inDirection direction: UITextDirection) -> Bool {
        pabort ("PROTO: MIT/position")
        return false
    }
}
#endif
