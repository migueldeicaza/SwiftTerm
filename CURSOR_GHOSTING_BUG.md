# Cursor Ghosting Bug Fix

## Problem

TUI (Text User Interface) applications like Claude Code, htop, and other ncurses-based apps would display "ghost cursors" - white cursor artifacts that remained visible at previous positions when the cursor moved.

## Root Cause

The `updateCursorPosition()` method in `Sources/SwiftTerm/Apple/AppleTerminalView.swift` was not removing the CaretView from the view hierarchy when the cursor was hidden.

TUI apps use DECTCEM escape sequences to control cursor visibility:
- `ESC[?25l` - Hide cursor
- `ESC[?25h` - Show cursor

The original code handled:
1. Cursor position off-screen → remove CaretView ✓
2. Cursor not hidden + CaretView not added → add CaretView ✓
3. **Cursor hidden → (missing logic)** ✗

This caused CaretView instances to accumulate in the view hierarchy as the cursor moved while hidden, creating visible ghost cursors.

## Fix

Added else clause in `updateCursorPosition()` (line 1206-1209):

```swift
} else if terminal.cursorHidden == true && caretView.superview == self {
    caretView.removeFromSuperview()
    return
}
```

Now when the terminal's cursor is hidden (`cursorHidden == true`), the CaretView is properly removed from the superview.

## Manual Testing Procedure

### Prerequisites
- macOS system
- TermQ or SwiftTerm sample app built with this fix
- Claude Code CLI tool (or any TUI app like htop, vim, etc.)

### Test Steps

1. **Build SwiftTerm with the fix:**
   ```bash
   swift build
   ```

2. **Run in TermQ:**
   - Launch TermQ
   - Run `claude` (or another TUI app)
   - Type some text and move around

3. **Expected Behavior (with fix):**
   - Cursor should move cleanly without leaving white artifacts
   - Only one cursor should be visible at a time
   - No "ghost cursors" at previous positions

4. **Without Fix (to verify the bug):**
   - Checkout commit before this fix
   - Rebuild and run same test
   - You should see white cursor artifacts remaining at previous positions
   - Multiple cursor-shaped rectangles visible simultaneously

### Verification Commands

To compare before/after:

```bash
# Test with fix
git checkout fix/cursor-ghosting-tui-apps
swift build
# Run TermQ and test with Claude Code

# Test without fix (show the bug)
git checkout HEAD~1
swift build
# Run TermQ and test with Claude Code - should see ghosting
```

## Technical Details

**File Modified:** `Sources/SwiftTerm/Apple/AppleTerminalView.swift`
**Function:** `updateCursorPosition()` (around line 1193)
**Lines Changed:** Added 4 lines (1206-1209)

**Escape Sequences Involved:**
- `\033[?25l` - DECTCEM - Hide text cursor
- `\033[?25h` - DECTCEM - Show text cursor
- `\033[{row};{col}H` - CUP - Cursor position

TUI apps typically:
1. Hide cursor: `\033[?25l`
2. Move cursor: `\033[{row};{col}H`
3. Write text at position
4. Show cursor: `\033[?25h`
5. Repeat rapidly during UI updates

## Testing Coverage

Since the Swift Testing framework has environment dependencies with the current setup, manual testing is the primary verification method for this fix.

**Affected Components:**
- CaretView management in AppleTerminalView
- DECTCEM escape sequence handling
- TUI application rendering

**Regression Risk:** Low
- Change is localized to cursor visibility handling
- Only affects CaretView removal logic
- Does not modify cursor positioning or rendering

## Related Issues

This bug was discovered when running Claude Code (a modern TUI application) in TermQ. The issue would appear as multiple white cursor rectangles visible simultaneously as you typed.

## Additional Notes

- This issue only affects macOS/AppKit (AppleTerminalView)
- iOS version may have similar code path but uses different view hierarchy
- The fix follows the existing pattern of removing CaretView when cursor is off-screen
