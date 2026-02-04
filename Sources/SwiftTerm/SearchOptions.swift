//
//  SearchOptions.swift
//  SwiftTerm
//
//  Ported from xterm.js search addon infrastructure.
//

import Foundation

/// Options that control terminal text search behavior.
public struct SearchOptions: Equatable {
    /// Whether the search is case sensitive.
    public var caseSensitive: Bool
    /// Whether the search term should be interpreted as a regular expression.
    public var regex: Bool
    /// Whether the match must be bounded by non-word characters.
    public var wholeWord: Bool

    /// Creates a new `SearchOptions`.
    public init (caseSensitive: Bool = false, regex: Bool = false, wholeWord: Bool = false) {
        self.caseSensitive = caseSensitive
        self.regex = regex
        self.wholeWord = wholeWord
    }
}
