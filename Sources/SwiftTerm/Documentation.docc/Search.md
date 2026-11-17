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

### Replacing the Find Bar

To keep the built-in behavior (the Find menu, the find pasteboard, searching as the user types)
but show your own view, implement ``TerminalFindBar`` in an `NSView` and hand it to the terminal:

```swift
terminalView.findBarProvider = { MyFindBar() }
```

The terminal places the view at its top trailing corner and becomes its
``TerminalFindBar/findBarDelegate``. Your view reports edits, option changes, next/previous and
close through ``TerminalFindBarDelegate``, and receives a ``TerminalFindStatus`` after each
search, which it can use to show a "2/14" counter or a "Not found" message.

## Custom Search UI

If you want your own UI (for example, a custom find bar, a toolbar item, or a command palette),
call the `TerminalView` helpers:

```swift
terminalView.findNext("term")
terminalView.findPrevious("term", options: SearchOptions(caseSensitive: true))
terminalView.clearSearch()
```

You can enable regular expressions and whole-word matching via `SearchOptions`.
