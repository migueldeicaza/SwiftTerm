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
search, which it can use to show a "Not found" message.

Counting the matches reads the whole scrollback, so the terminal only does it for a bar that
returns `true` from ``TerminalFindBar/showsMatchCount``. Such a bar receives
``TerminalFindStatus/matches(current:total:capped:)`` for a "2/14" counter: at once when the
user goes to the next or previous match, shortly after they stop typing, and again when new
output changes the count.

The terminal lays the bar out with Auto Layout. Size it with constraints or an intrinsic
content size; a view that only has a frame keeps that frame's size.

## Custom Search UI

If you want your own UI (for example, a custom find bar, a toolbar item, or a command palette),
call the `TerminalView` helpers:

```swift
terminalView.findNext("term")
terminalView.findPrevious("term", options: SearchOptions(caseSensitive: true))
terminalView.clearSearch()
```

You can enable regular expressions and whole-word matching via `SearchOptions`.
