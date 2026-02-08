//
//  SearchState.swift
//  SwiftTerm
//
//  Ported from xterm.js search addon infrastructure.
//

import Foundation

final class SearchState {
    var cachedSearchTerm: String?
    var lastSearchOptions: SearchOptions?

    func isValidSearchTerm (_ term: String) -> Bool {
        return !term.isEmpty
    }

    func didOptionsChange (_ newOptions: SearchOptions?) -> Bool {
        guard let lastSearchOptions else {
            return true
        }
        guard let newOptions else {
            return false
        }
        return lastSearchOptions.caseSensitive != newOptions.caseSensitive ||
            lastSearchOptions.regex != newOptions.regex ||
            lastSearchOptions.wholeWord != newOptions.wholeWord
    }

    func reset () {
        cachedSearchTerm = nil
        lastSearchOptions = nil
    }
}
