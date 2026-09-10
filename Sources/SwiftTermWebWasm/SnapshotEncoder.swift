import SwiftTerm

/// Encodes ABI 1 with explicit little-endian stores and checked size arithmetic.
enum SnapshotEncoder {
    static func color(_ value: RenderSnapshotColor) -> UInt32 {
        ABI.color(value.red, value.green, value.blue)
    }
    static func resolve(_ value: Attribute.Color, _ source: TerminalRenderSnapshot, foreground: Bool = true) -> UInt32 {
        let useForeground = foreground != source.reverseVideo
        switch value {
        case .defaultColor: return color(useForeground ? source.foregroundColor : source.backgroundColor)
        case .defaultInvertedColor: return color(useForeground ? source.backgroundColor : source.foregroundColor)
        case .ansi256(let code):
            return Int(code) < source.palette.count ? color(source.palette[Int(code)]) : color(source.foregroundColor)
        case .trueColor(let red, let green, let blue):
            return UInt32(red) << 24 | UInt32(green) << 16 | UInt32(blue) << 8 | 255
        }
    }
    static func semantic(_ value: SemanticContent) -> UInt8 {
        switch value {
        case .none: return 0
        case .prompt(let kind):
            switch kind {
            case .initial: return 1
            case .right: return 2
            case .continuation: return 3
            case .secondary: return 4
            }
        case .input: return 5
        case .output: return 6
        }
    }
    static func add(_ lhs: Int, _ rhs: Int) -> Int? {
        let result = lhs.addingReportingOverflow(rhs)
        return !result.overflow && result.partialValue <= ABI.maximumSnapshot ? result.partialValue : nil
    }
    static func multiply(_ lhs: Int, _ rhs: Int) -> Int? {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        return !result.overflow && result.partialValue <= ABI.maximumSnapshot ? result.partialValue : nil
    }
    static func encode(_ source: TerminalRenderSnapshot, generation: UInt64, focused: Bool, into bytes: inout [UInt8]) -> Bool {
        guard source.cols >= 2 && source.cols <= 1024 && source.rows >= 1 && source.rows <= 1024,
              source.lines.count <= source.rows else { return false }
        var cells = 0
        var textSize = 0
        for row in source.lines {
            guard row.y >= 0 && row.y < source.rows, row.cells.count == source.cols,
                  let nextCells = add(cells, row.cells.count) else { return false }
            cells = nextCells
            for cell in row.cells {
                let length = cell.text.utf8.count
                guard length <= ABI.maximumControl, let nextText = add(textSize, length) else { return false }
                textSize = nextText
            }
        }
        guard let rowSize = multiply(source.lines.count, 16), let cellSize = multiply(cells, 32),
              let cellOffset = add(104, rowSize), let textOffset = add(cellOffset, cellSize),
              let total = add(textOffset, textSize) else { return false }
        bytes.removeAll(keepingCapacity: true)
        bytes.append(contentsOf: repeatElement(UInt8(0), count: total))
        bytes.put32(0x53575453, at: 0)
        bytes.put16(1, at: 4)
        bytes.put16(104, at: 6)
        bytes.put32(UInt32(truncatingIfNeeded: generation), at: 8)
        bytes.put32(UInt32(truncatingIfNeeded: generation >> 32), at: 12)
        var flags: UInt32 = 0
        if source.isAlternateScreen { flags |= 1 }
        if source.reverseVideo { flags |= 2 }
        if focused { flags |= 4 }
        if source.synchronizedOutputActive { flags |= 8 }
        bytes.put32(flags, at: 16)
        bytes.put32(UInt32(source.cols), at: 20)
        bytes.put32(UInt32(source.rows), at: 24)
        bytes.put32(source.dirtyKind.rawValue, at: 28)
        bytes.put32(UInt32(source.lines.count), at: 32)
        bytes.put32(UInt32(bitPattern: Int32(clamping: source.dirtyRange?.startY ?? -1)), at: 36)
        bytes.put32(UInt32(bitPattern: Int32(clamping: source.dirtyRange?.endY ?? -1)), at: 40)
        bytes.put32(UInt32(bitPattern: Int32(clamping: source.scrollDirtyRange?.startY ?? -1)), at: 44)
        bytes.put32(UInt32(bitPattern: Int32(clamping: source.scrollDirtyRange?.endY ?? -1)), at: 48)
        bytes.put32(UInt32(clamping: min(source.cols, max(0, source.cursor.x))), at: 52)
        bytes.put32(UInt32(bitPattern: Int32(clamping: source.cursor.y)), at: 56)
        bytes[60] = ABI.cursor(source.cursor.style).shape
        bytes[61] = source.cursor.hidden ? 0 : 1
        bytes[62] = source.cursor.blink ? 1 : 0
        var defaultForeground = color(source.foregroundColor)
        var defaultBackground = color(source.backgroundColor)
        if source.reverseVideo { swap(&defaultForeground, &defaultBackground) }
        bytes.put32(defaultForeground, at: 64)
        bytes.put32(defaultBackground, at: 68)
        bytes.put32(source.cursorColor.map { color($0) } ?? defaultForeground, at: 72)
        bytes.put32(104, at: 76)
        bytes.put32(UInt32(cellOffset), at: 80)
        bytes.put32(UInt32(cells), at: 84)
        bytes.put32(UInt32(textOffset), at: 88)
        bytes.put32(UInt32(textSize), at: 92)
        var cellIndex = 0
        var textIndex = 0
        for (rowIndex, row) in source.lines.enumerated() {
            let offset = 104 + rowIndex * 16
            bytes.put32(UInt32(row.y), at: offset)
            var rowFlags: UInt32 = row.wrapsToNext ? 1 : 0
            switch row.renderMode {
            case .single: break
            case .doubleWidth: rowFlags |= 2
            case .doubledTop: rowFlags |= 4
            case .doubledDown: rowFlags |= 8
            }
            bytes.put32(rowFlags, at: offset + 4)
            bytes.put32(UInt32(cellIndex), at: offset + 8)
            bytes.put32(UInt32(row.cells.count), at: offset + 12)
            for cell in row.cells {
                let at = cellOffset + cellIndex * 32
                let attribute = cell.attribute
                var fg = resolve(attribute.fg, source)
                var bg = resolve(attribute.bg, source, foreground: false)
                if attribute.style.contains(.inverse) { swap(&fg, &bg) }
                bytes.put32(UInt32(textIndex), at: at)
                bytes.put32(UInt32(cell.text.utf8.count), at: at + 4)
                bytes.put32(fg, at: at + 8)
                bytes.put32(bg, at: at + 12)
                bytes.put32(attribute.underlineColor.map { resolve($0, source) } ?? fg, at: at + 16)
                bytes.put16(UInt16(attribute.style.rawValue), at: at + 24)
                bytes[at + 26] = UInt8(clamping: cell.width)
                bytes[at + 27] = attribute.underlineStyle.rawValue
                bytes[at + 28] = semantic(cell.semanticContent)
                var cellFlags: UInt8 = cell.isProtected ? 2 : 0
                switch cell.widthState {
                case .narrow, .wide: break
                case .spacerTail: cellFlags |= 4
                case .spacerHead: cellFlags |= 16
                }
                if attribute.underlineColor != nil { cellFlags |= 8 }
                #if !SWIFTTERM_EMBEDDED
                if cell.text.unicodeScalars.first?.value == 0x10eeee { cellFlags |= 64 }
                #endif
                if !attribute.style.contains(.inverse) && attribute.bg == .defaultColor { cellFlags |= 32 }
                bytes[at + 29] = cellFlags
                for byte in cell.text.utf8 { bytes[textOffset + textIndex] = byte; textIndex += 1 }
                cellIndex += 1
            }
        }
        return true
    }

    /// Keep the last header, but discard its rows after the host accepts a frame.
    static func clean(_ bytes: inout [UInt8]) {
        guard bytes.count >= 104 else { return }
        bytes.removeSubrange(104...)
        bytes.put32(0, at: 28)
        bytes.put32(0, at: 32)
        for offset in [36, 40, 44, 48] { bytes.put32(UInt32.max, at: offset) }
        bytes.put32(104, at: 76)
        bytes.put32(104, at: 80)
        bytes.put32(0, at: 84)
        bytes.put32(104, at: 88)
        bytes.put32(0, at: 92)
    }
}
