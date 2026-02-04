//
//  SearchOptions.swift
//  SwiftTerm
//
//  Ported from xterm.js search addon infrastructure.
//

import Foundation

public struct SearchOptions: Equatable {
    public var caseSensitive: Bool
    public var regex: Bool
    public var wholeWord: Bool

    public init (caseSensitive: Bool = false, regex: Bool = false, wholeWord: Bool = false) {
        self.caseSensitive = caseSensitive
        self.regex = regex
        self.wholeWord = wholeWord
    }
}
