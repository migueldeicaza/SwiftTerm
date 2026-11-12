//
// Rare command paths. They are in their own file, so that the compiler puts
// their code in a different object file: code added to Terminal.swift moves
// the hot command handlers (cmdCsiM in particular), and the benchmarks show
// that a move can cost some percent of cycles with no change in instructions.
//

extension Terminal {
    /// Keeps the host color under an OSC 10 or OSC 11 color. When the current
    /// color is not the last OSC color, the host changed it, so it is the new
    /// host color.
    static func dynamicColorOverride(_ slot: (host: Color, osc: Color)?, current: Color, new: Color) -> (host: Color, osc: Color) {
        if let slot, slot.osc == current {
            return (slot.host, new)
        }
        return (current, new)
    }

    /// OSC 110 and OSC 111: restore the default foreground or background, which
    /// is the color that the host set. When the host changed the color after the
    /// OSC 10 or OSC 11, its color is already the default. Setting the color
    /// notifies the delegate.
    func oscResetDynamicColor (foreground: Bool)
    {
        if foreground {
            if let slot = cold.foregroundOverride, slot.osc == foregroundColor {
                foregroundColor = slot.host
            }
            cold.foregroundOverride = nil
        } else {
            if let slot = cold.backgroundOverride, slot.osc == backgroundColor {
                backgroundColor = slot.host
            }
            cold.backgroundOverride = nil
        }
    }

    /// DECSET 41 (more(1) fix): TAB with a pending wrap first wraps to the
    /// next line.
    @inline(never)
    func tabWrapForMoreFix ()
    {
        buffer.wrapCursorToNextLine()
        buffer.pendingWrap = false
    }
}
