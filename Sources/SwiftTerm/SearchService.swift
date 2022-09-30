//
//  File.swift
//  
//
//  Created by Miguel de Icaza on 3/5/20.
//

import Foundation

/// Options for a search
public struct SearchOptions {
    /// Whether the search term is a regex.
    var regex: Bool
    
    ///  Whether to search for a whole word, the result is only valid if it's
    ///  surrounded in "non-word" characters such as `_`, `(`, `)` or space.
    var wholeWord: Bool
    
    ///  Whether the search is case sensitive.
    var caseSensitive: Bool
    
    /// Whether to do an incremental search, this will expand the selection if it
    /// still matches the term the user typed. Note that this only affects
    /// `findNext`, not `findPrevious`.
    var incremental: Bool
}

public struct SearchResult {
    var term: String
    var pos: Position
    var size: Int
}

/// Options for showing decorations when searching
public struct SearchDecorationOptions {
    
}

struct LineCacheEntry {
     /// The string representation of a line (as opposed to the buffer cell representation).
    var lineAsString: String
    /// The offsets where each line starts when the entry describes a wrapped line.
    var lineOffsets: [Int]
}

public class SearchService {
    var terminal: Terminal
    var lastSearchOptions: SearchOptions?
    var selectionService: SelectionService
    
    //var selection: SelectionService
    //var cache: SearchSnapshot
    
    init (terminal: Terminal, selectionService: SelectionService)
    {
        self.terminal = terminal
        self.selectionService = selectionService
    }
    
    /// Search forwards for the next result that matches the search term and options.
    /// - Parameters:
    ///   - term: The search term
    ///   - searchOptions: Options for this search, or nil for the defaults
    /// - Returns: true if a match was found
    public func findNext (term: String, searchOptions: SearchOptions? = nil) -> Bool {
        lastSearchOptions = searchOptions
        
        if term == "" {
            selectionService.selectNone()
            return false
        }
        
        var startCol = 0
        var startRow = 0
        var currentSelection: (Position, Position)? = nil
        if selectionService.hasSelectionRange {
            let incremental = searchOptions?.incremental ?? false
            // Start from the selection end if there is a selection
            // For incremental search, use existing row
            let sel = (selectionService.start, selectionService.end)
            currentSelection = sel
            startRow = incremental ? sel.0.row : sel.1.row
            startCol = incremental ? sel.0.col : sel.1.col
        }
        
        var searchPosition = Position (col: startCol, row: startRow)
        
        // Search startRow
        var result = findInLine(term: term, startPos: searchPosition, searchOptions: searchOptions)
        
        // Search from startRow + 1 to end
        if result != nil {
            for y in startRow+1..<terminal.buffer.yBase + terminal.rows {
                searchPosition.row = y
                searchPosition.col = 0
                // If the current line is wrapped line, increase index of column to ignore the previous scan
                // Otherwise, reset beginning column index to zero with set new unwrapped line index
                result = findInLine(term: term, startPos: searchPosition, searchOptions: searchOptions)
                if result != nil {
                    break
                }
            }
        }
        // If we hit the bottom and didn't search from the very top wrap back up
        if result != nil && startRow != 0 {
            for y in 0..<startRow {
                searchPosition.row = y
                searchPosition.col = 0
                result = findInLine(term: term, startPos: searchPosition, searchOptions: searchOptions)
                if result != nil {
                    break
                }
            }
        }
        
        // If there is only one result, wrap back and return selection if it exists.
        if result != nil {
            if let currentSelection = currentSelection {
                searchPosition.row = currentSelection.0.row
                searchPosition.col = 0
                result = findInLine(term: term, startPos: searchPosition, searchOptions: searchOptions)
            }
        }
        
        // Set selection and scroll if a result was found
        return selectResult(result)
    }
    
    func selectResult (_ result: SearchResult?) -> Bool {
        guard let result = result else {
            selectionService.selectNone()
            return false
        }
        selectionService.setSelection(start: result.pos, length: result.size)
    }
    
    /// Translates a buffer line to a string, including subsequent lines if they are wraps.
    /// Wide characters will count as two columns in the resulting string. This
    /// function is useful for getting the actual text underneath the raw selection
    /// position.
    /// - Parameters:
    ///  - line: The line being translated.
    ///  - trimRight: Whether to trim whitespace to the right.
    /// - Returns a translated line
    func translateBufferLineToStringWithWrap(lineIndex startIndex: Int, trimRight: Bool) -> LineCacheEntry {
        var result = ""
        var lineOffsets = [0]
        var lineIndex = startIndex
        var line = terminal.buffer.lines [lineIndex]
        while true {
            let nextLine = terminal.buffer.lines [lineIndex + 1]
            let lineWrapsToNext = nextLine.isWrapped
            var string = line.translateToCharArray(trimRight: !lineWrapsToNext && trimRight)
            if lineWrapsToNext {
                let lastCell = line [line.count - 1]
                let lastCellIsNull = lastCell.code == 0 && lastCell.width == 1
                // a wide character wrapped to the next line
                if lastCellIsNull && nextLine [0].width == 2 {
                    string = string.dropLast()
                }
            }
            result.append (String (string))
            if lineWrapsToNext {
                lineOffsets.append(lineOffsets[lineOffsets.count - 1] + string.count)
            } else {
                break
            }
            lineIndex += 1
            line = nextLine
        }
        return LineCacheEntry (lineAsString: result, lineOffsets: lineOffsets)
    }
    
    /// Searches a line for a search term. Takes the provided terminal line and searches the text line, which may contain
    /// subsequent terminal lines if the text is wrapped. If the provided line number is part of a wrapped text line that
    /// started on an earlier line then it is skipped since it will be properly searched when the terminal line that the
    /// text starts on is searched.
    /// - Parameters:
    ///  - term: The search term.
    ///  - position: The position to start the search.
    ///  - searchOptions: Search options.
    ///  - isReverseSearch: Whether the search should start from the right side of the terminal and search to the left.
    /// - Returns: The search result if it was found, nil if not.
    ///
    func findInLine(term: String, startPos: Position, searchOptions: SearchOptions? = nil, isReverseSearch: Bool = false) -> SearchResult? {
        var searchPosition = startPos
        let row = searchPosition.row
        let col = searchPosition.col
        
        // Ignore wrapped lines, only consider on unwrapped line (first row of command string).
        let firstLine = terminal.buffer.lines [row]
        if firstLine.isWrapped {
            if isReverseSearch {
                searchPosition.col += terminal.cols
                return nil
            }
            
            // This will iterate until we find the line start.
            // When we find it, we will search using the calculated start column.
            searchPosition.row -= 1
            searchPosition.col += terminal.cols
            return findInLine(term: term, startPos: searchPosition, searchOptions: searchOptions)
        }
        let cache = translateBufferLineToStringWithWrap(lineIndex: row, trimRight: true)
        let stringLine = cache.lineAsString
        offset = cache.lineOffsets

        
         offset = bufferColsToStringOffset (startRow: row, col)
        const searchTerm = searchOptions.caseSensitive ? term : term.toLowerCase();
        const searchStringLine = searchOptions.caseSensitive ? stringLine : stringLine.toLowerCase();
        
        let resultIndex = -1;
        if (searchOptions.regex) {
            const searchRegex = RegExp(searchTerm, 'g');
            let foundTerm: RegExpExecArray | null;
            if (isReverseSearch) {
                // This loop will get the resultIndex of the _last_ regex match in the range 0..offset
                while (foundTerm = searchRegex.exec(searchStringLine.slice(0, offset))) {
                    resultIndex = searchRegex.lastIndex - foundTerm[0].length;
                    term = foundTerm[0];
                    searchRegex.lastIndex -= (term.length - 1);
                }
            } else {
                foundTerm = searchRegex.exec(searchStringLine.slice(offset));
                if (foundTerm && foundTerm[0].length > 0) {
                    resultIndex = offset + (searchRegex.lastIndex - foundTerm[0].length);
                    term = foundTerm[0];
                }
            }
        } else {
            if (isReverseSearch) {
                if (offset - searchTerm.length >= 0) {
                    resultIndex = searchStringLine.lastIndexOf(searchTerm, offset - searchTerm.length);
                }
            } else {
                resultIndex = searchStringLine.indexOf(searchTerm, offset);
            }
        }
        
        if (resultIndex >= 0) {
            if (searchOptions.wholeWord && !this._isWholeWord(resultIndex, searchStringLine, term)) {
                return;
            }
            
            // Adjust the row number and search index if needed since a "line" of text can span multiple rows
            let startRowOffset = 0;
            while (startRowOffset < offsets.length - 1 && resultIndex >= offsets[startRowOffset + 1]) {
                startRowOffset++;
            }
            let endRowOffset = startRowOffset;
            
            offsets[endRowOffset + 1]) {
                endRowOffset++;
            }
            const startColOffset = resultIndex - offsets[startRowOffset];
            const endColOffset = resultIndex + term.length - offsets[endRowOffset];
            const startColIndex = this._stringLengthToBufferSize(row + startRowOffset, startColOffset);
            const endColIndex = this._stringLengthToBufferSize(row + endRowOffset, endColOffset);
            const size = endColIndex - startColIndex + terminal.cols * (endRowOffset - startRowOffset);
            
            return {
                term,
            col: startColIndex,
            row: row + startRowOffset,
                size
            };
        }
    }
    
//
//const NON_WORD_CHARACTERS = ' ~!@#$%^&*()+`-=[]{}|\\;:"\',./<>?';
//const LINES_CACHE_TIME_TO_LIVE = 15 * 1000; // 15 secs
//
//export class SearchAddon implements ITerminalAddon {
//  private _terminal: Terminal | undefined;
//
//  /**
//   * translateBufferLineToStringWithWrap is a fairly expensive call.
//   * We memoize the calls into an array that has a time based ttl.
//   * _linesCache is also invalidated when the terminal cursor moves.
//   */
//  private _linesCache: LineCacheEntry[] | undefined;
//  private _linesCacheTimeoutId = 0;
//  private _cursorMoveListener: IDisposable | undefined;
//  private _resizeListener: IDisposable | undefined;
//
//  public activate(terminal: Terminal): void {
//    this._terminal = terminal;
//  }
//
//  public dispose(): void { }
//

//
//  /**
//   * Find the previous instance of the term, then scroll to and select it. If it
//   * doesn't exist, do nothing.
//   * @param term The search term.
//   * @param searchOptions Search options.
//   * @return Whether a result was found.
//   */
//  public findPrevious(term: string, searchOptions?: ISearchOptions): boolean {
//    if (!this._terminal) {
//      throw new Error('Cannot use addon until it has been loaded');
//    }
//
//    if (!term || term.length === 0) {
//      this._terminal.clearSelection();
//      return false;
//    }
//
//    const isReverseSearch = true;
//    let startRow = this._terminal.buffer.active.baseY + this._terminal.rows;
//    let startCol = this._terminal.cols;
//    let result: ISearchResult | undefined;
//    const incremental = searchOptions ? searchOptions.incremental : false;
//    let currentSelection: ISelectionPosition | undefined;
//    if (this._terminal.hasSelection()) {
//      currentSelection = this._terminal.getSelectionPosition()!;
//      // Start from selection start if there is a selection
//      startRow = currentSelection.startRow;
//      startCol = currentSelection.startColumn;
//    }
//
//    this._initLinesCache();
//    const searchPosition: ISearchPosition = {
//      startRow,
//      startCol
//    };
//
//    if (incremental) {
//      // Try to expand selection to right first.
//      result = this._findInLine(term, searchPosition, searchOptions, false);
//      const isOldResultHighlighted = result && result.row === startRow && result.col === startCol;
//      if (!isOldResultHighlighted) {
//        // If selection was not able to be expanded to the right, then try reverse search
//        if (currentSelection) {
//          searchPosition.startRow = currentSelection.endRow;
//          searchPosition.startCol = currentSelection.endColumn;
//        }
//        result = this._findInLine(term, searchPosition, searchOptions, true);
//      }
//    } else {
//      result = this._findInLine(term, searchPosition, searchOptions, isReverseSearch);
//    }
//
//    // Search from startRow - 1 to top
//    if (!result) {
//      searchPosition.startCol = Math.max(searchPosition.startCol, this._terminal.cols);
//      for (let y = startRow - 1; y >= 0; y--) {
//        searchPosition.startRow = y;
//        result = this._findInLine(term, searchPosition, searchOptions, isReverseSearch);
//        if (result) {
//          break;
//        }
//      }
//    }
//    // If we hit the top and didn't search from the very bottom wrap back down
//    if (!result && startRow !== (this._terminal.buffer.active.baseY + this._terminal.rows)) {
//      for (let y = (this._terminal.buffer.active.baseY + this._terminal.rows); y >= startRow; y--) {
//        searchPosition.startRow = y;
//        result = this._findInLine(term, searchPosition, searchOptions, isReverseSearch);
//        if (result) {
//          break;
//        }
//      }
//    }
//
//    // If there is only one result, return true.
//    if (!result && currentSelection) return true;
//
//    // Set selection and scroll if a result was found
//    return this._selectResult(result);
//  }
//
//  /**
//   * Sets up a line cache with a ttl
//   */
//  private _initLinesCache(): void {
//    const terminal = this._terminal!;
//    if (!this._linesCache) {
//      this._linesCache = new Array(terminal.buffer.active.length);
//      this._cursorMoveListener = terminal.onCursorMove(() => this._destroyLinesCache());
//      this._resizeListener = terminal.onResize(() => this._destroyLinesCache());
//    }
//
//    window.clearTimeout(this._linesCacheTimeoutId);
//    this._linesCacheTimeoutId = window.setTimeout(() => this._destroyLinesCache(), LINES_CACHE_TIME_TO_LIVE);
//  }
//
//  private _destroyLinesCache(): void {
//    this._linesCache = undefined;
//    if (this._cursorMoveListener) {
//      this._cursorMoveListener.dispose();
//      this._cursorMoveListener = undefined;
//    }
//    if (this._resizeListener) {
//      this._resizeListener.dispose();
//      this._resizeListener = undefined;
//    }
//    if (this._linesCacheTimeoutId) {
//      window.clearTimeout(this._linesCacheTimeoutId);
//      this._linesCacheTimeoutId = 0;
//    }
//  }
//
//  /**
//   * A found substring is a whole word if it doesn't have an alphanumeric character directly adjacent to it.
//   * @param searchIndex starting indext of the potential whole word substring
//   * @param line entire string in which the potential whole word was found
//   * @param term the substring that starts at searchIndex
//   */
//  private _isWholeWord(searchIndex: number, line: string, term: string): boolean {
//    return ((searchIndex === 0) || (NON_WORD_CHARACTERS.includes(line[searchIndex - 1]))) &&
//      (((searchIndex + term.length) === line.length) || (NON_WORD_CHARACTERS.includes(line[searchIndex + term.length])));
//  }
//

//  private _stringLengthToBufferSize(row: number, offset: number): number {
//    const line = this._terminal!.buffer.active.getLine(row);
//    if (!line) {
//      return 0;
//    }
//    for (let i = 0; i < offset; i++) {
//      const cell = line.getCell(i);
//      if (!cell) {
//        break;
//      }
//      // Adjust the searchIndex to normalize emoji into single chars
//      const char = cell.getChars();
//      if (char.length > 1) {
//        offset -= char.length - 1;
//      }
//      // Adjust the searchIndex for empty characters following wide unicode
//      // chars (eg. CJK)
//      const nextCell = line.getCell(i + 1);
//      if (nextCell && nextCell.getWidth() === 0) {
//        offset++;
//      }
//    }
//    return offset;
//  }
//
    func bufferColsToStringOffset (startRow: Int, _ xcols: Int) -> Int  {
        var lineIndex = startRow
        var offset = 0
        var line = terminal.buffer.lines [lineIndex]
        var cols = xcols
        while cols > 0 {
            var i = 0
            while i < cols && i < terminal.cols {
                defer { i += 1 }
                let cell = line [i]
                if cell.code == 0 {
                    break
                }
                offset += Int (cell.width)
            }
            lineIndex += 1
            line = terminal.buffer.lines [lineIndex]
            if !line.isWrapped {
                break
            }
            cols -= terminal.cols
        }
        return offset
    }


//  /**
//   * Selects and scrolls to a result.
//   * @param result The result to select.
//   * @return Whethera result was selected.
//   */
//  private _selectResult(result: ISearchResult | undefined): boolean {
//    const terminal = this._terminal!;
//    if (!result) {
//      terminal.clearSelection();
//      return false;
//    }
//    terminal.select(result.col, result.row, result.size);
//    // If it is not in the viewport then we scroll else it just gets selected
//    if (result.row >= (terminal.buffer.active.viewportY + terminal.rows) || result.row < terminal.buffer.active.viewportY) {
//      let scroll = result.row - terminal.buffer.active.viewportY;
//      scroll -= Math.floor(terminal.rows / 2);
//      terminal.scrollLines(scroll);
//    }
//    return true;
//  }
//}
}
