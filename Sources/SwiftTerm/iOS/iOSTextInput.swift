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
// This extension implements the support for UITextInput
extension TerminalView : UITextInput {
    func pabort (_ msg: String)
    {
        print (msg)
        abort ()
    }

    public func text(in range: UITextRange) -> String? {
        guard let termRange = range as? TerminalTextRange,
              let start = (termRange.start as? TerminalTextPosition)?.pos,
              let end = (termRange.end as? TerminalTextPosition)?.pos else {
            return nil
        }
        
        let text = terminal.getText(start: start, end: end)
        
        print ("text(in range: \(start)-\(end)) -> \"\(text)\"")
        return text
    }

    public func replace(_ range: UITextRange, withText text: String) {
        guard let r = range as? TerminalTextRange else {
            pabort ("replace: Called with a non TerminalTextRange")
            return
        }
        print ("Replace \(range) with \(text)")
        if text == "" {
            return
        }
        print ("REPLACE: found a replacement with body: \(text)")
    }

    func makeRange (start: Position, end: Position) -> TerminalTextRange {
        return TerminalTextRange (start: TerminalTextPosition (start), end: TerminalTextPosition (end))
    }
    
    public var selectedTextRange: UITextRange? {
        get {
            
            // TODO: rather than creating this every time, create it when the selection
            // is changed, and always update _selectionTextRange
            // This is temporary while I get the other methods working
            if selection.active && selection.hasSelectionRange {
                return makeRange(start: selection.start, end: selection.end)
            }
            let b = terminal.buffer
            let cursor = Position(col: b.x, row: b.y)
            return makeRange(start: cursor, end: cursor)
        }
        set {
            if let newRange = newValue as? TerminalTextRange {
                if let start = (newRange.start as? TerminalTextPosition),
                    let end = (newRange.end as? TerminalTextPosition) {

                    selection.setSelection(start: start.pos, end: end.pos)
                }
            } else {
                selection.active = false
            }
        }
    }

    // TODO: we should track the markedTextRange in a struct, not an NSObject, and just create here on demand
    public var markedTextRange: UITextRange? {
        get {
            return _markedTextRange
        }
    }

    public var markedTextStyle: [NSAttributedString.Key : Any]? {
        get {
            pabort ("PROTO: markedTextStyle")
            return nil
        }
        set {
            pabort ("PROTO: set markedTextStyle")
        }
    }

    func advance (position: Position, offset: Int) -> Position
    {
        let b = terminal.buffer
        let p = position.col + offset
        let lines = p / b.cols
        let cols = p % b.cols
        let lineAbs = position.row + lines
        
        // TODO: perhaps this should not be "advance" relative to the start
        // but instead it should update both markedTextRange start and end, as
        // if the boundary crosses the lines, then it should scroll the beggining
        // as well
        
        // Wrap the line around
        let line = min (lineAbs, b.rows-1)
        return Position(col: position.col + cols, row: line)
    }
    
    public func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        if let mtr = _markedTextRange {
            let text = markedText ?? ""
            
            print ("TODO: replaceCahracterInRange (markedTextRange) with the text")
            
            mtr._end = TerminalTextPosition (advance (position: mtr._start.pos, offset: text.count))
        } else if selectedRange.length > 0 {
            // There is no marked range, but there is a selected range
            // so replace text storage at selected range and updated markedTextRange
            
        }
    }

    public func unmarkText() {
        pabort ("PROTO: unmarktext")
    }

    public var beginningOfDocument: UITextPosition {
        get {
            let b = terminal.buffer
            return TerminalTextPosition(Position (col: b.x, row: b.y))
        }
    }

    public var endOfDocument: UITextPosition {
        get {
            let b = terminal.buffer
            return TerminalTextPosition(Position (col: terminal.cols, row: b.y))
        }
    }

    public func beginFloatingCursor(at: CGPoint) {
        print ("oo")
    }
    public func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? TerminalTextPosition, let to = toPosition as? TerminalTextPosition else {
            fatalError()
        }
        print("[Geometry] form range [\(from.pos) ..< \(to.pos)]")
        
        return TerminalTextRange(start: from, end: to)
    }

    public func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let pos = position as? TerminalTextPosition else {
            abort ()
        }
        print ("POSITION-offset: \(pos.pos) \(offset)")
        let p = (position as! TerminalTextPosition).pos
        var col = p.col + offset
        col = min (max (col, 0), terminal.cols-1)
        print ("POSITION-offset: \(pos.pos) \(offset) going to-> \(col)")
        return TerminalTextPosition (Position (col: col, row: p.row))
        return nil
    }

    public func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        pabort ("PROTO: position2")
        return nil
    }

    public func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        if let a = position as? TerminalTextPosition {
            if let b = other as? TerminalTextPosition {
                switch Position.compare(a.pos, b.pos){
                case .before:
                    return .orderedAscending
                case .after:
                    return .orderedDescending
                case .equal:
                    return .orderedSame
                }
            }
        }
        return .orderedSame
    }

    public func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard let start = from as? TerminalTextPosition, let end = toPosition as? TerminalTextPosition else {
          fatalError()
        }
        let str = terminal.getText (start: start.pos, end: end.pos)
        return str.utf16.count
    }

    public func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        pabort ("PROTO: position3")
        return nil
    }

    public func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        pabort ("PROTO: characterRnage")
        return nil
    }

    public func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        return .leftToRight
    }

    public func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {
        pabort ("PROTO: setBaseWritingDirection")

    }

    public func firstRect(for range: UITextRange) -> CGRect {
        guard let r = range as? TerminalTextRange else {
            pabort ("firstRect (for range: UITextRange) received a non-TerminalTextRange")
            return CGRect.zero
        }
        print ("TODO: firstRect (for Range) needs SCROLLSUPPORT + CORRECTREGION)")
        return bounds
    }

    public func caretRect(for position: UITextPosition) -> CGRect {
        guard let pos = position as? TerminalTextPosition  else {
            abort ()
        }
        
        print ("PROTO: caretRect for \(pos.pos)")
        return bounds
    }

    // Trigger this by hitting the microphone
    public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        guard let myRange = range as? TerminalTextRange else {
            print ("FATAL/PROTO: selectionRects does not get a TerminalTextRange")
            abort ()
            return []
        }
        print ("TODO: selectionRects (for Range) needs SCROLLSUPPORT + CORRECTREGION)")
        return [TerminalSelectionRect(rect: bounds, range: myRange, string: text (in: range) ?? "")]
    }

    // Trigger this by long-pressing the space-bar
    public func closestPosition(to point: CGPoint) -> UITextPosition? {
        let col = min (max (0, Int (point.x / cellDimension.width)), terminal.rows)
        let row = min (max (0, Int (point.y / cellDimension.height)), terminal.cols)
        
        // TODO: probably this should return a position offset by the scroll position
        print ("closestPosition called for \(point)")
        return TerminalTextPosition (Position (col: col, row: row))
    }

    public func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        pabort ("PROTO: closestPosition")
        return nil
    }

    public func characterRange(at point: CGPoint) -> UITextRange? {
        pabort ("PROTO: characterRange")
        return nil
    }
}
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
            return "(col=\(pos.col),row=\(pos.row)"
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

    init(rect: CGRect, range: TerminalTextRange, string: String) {
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
