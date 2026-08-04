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
