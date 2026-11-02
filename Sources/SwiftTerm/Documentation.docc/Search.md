# Search

SwiftTerm includes built-in search support for `TerminalView` and a macOS find bar that integrates
with the standard **Edit > Find** menu. You can also build your own search UI by calling the
search helpers directly.

## Built-in macOS Find Bar

When running on macOS, `TerminalView` provides a floating find bar that supports:

- `Cmd-F` to open
- Next/Previous navigation
- Use Selection for Find
- Case sensitive, regex, and whole-word options

## Custom Search UI

If you want your own UI (for example, a custom find bar, a toolbar item, or a command palette),
call the `TerminalView` helpers:

```swift
terminalView.findNext("term")
terminalView.findPrevious("term", options: SearchOptions(caseSensitive: true))
terminalView.clearSearch()
```

You can enable regular expressions and whole-word matching via `SearchOptions`.

`searchMatchSummary` gives the current match's position among all matches (`2/14`) for a counter.

## Highlighting every match

By default only the current match is shown: it becomes the selection. With
`highlightAllSearchMatches` on, `findNext` and `findPrevious` also paint every other match of
the term in `searchMatchBackgroundColor` / `searchMatchForegroundColor` (yellow and black by
default), the way a find bar marks all hits while the selection walks them. `clearSearch`
removes the highlights.

```swift
terminalView.highlightAllSearchMatches = true
terminalView.searchMatchBackgroundColor = .systemYellow
```

The highlights stay where they were put until the next search call or `clearSearch`; after
output arrives, `findNext`/`findPrevious` or a `searchMatchSummary` recount recomputes them (the
counter and the highlights share one match list, so the second call is cheap).

To mark the matches outside the text — a tick per match beside the scrollbar — read their
positions:

```swift
let (matches, lines) = terminalView.searchMatchPositions("term")
for match in matches {
    let fraction = Double(match.row) / Double(lines)   // 0 = oldest scrollback line
}
```
