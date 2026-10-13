func terminalRowText(
    cellCount: Int,
    trimRight: Bool = true,
    startCol: Int = 0,
    endCol: Int = -1,
    logicalCode: (Int) -> Int32,
    width: (Int) -> Int,
    text: (Int) -> String
) -> String {
    var endColumn = endCol == -1 ? cellCount : endCol
    if trimRight {
        var trimmedLength = 0
        if cellCount > 0 {
            for index in stride(from: cellCount - 1, through: 0, by: -1) {
                if logicalCode(index) != 0 {
                    let remainingCells = cellCount - index
                    let cellWidth = min(max(0, width(index)), remainingCells)
                    trimmedLength = index + cellWidth
                    break
                }
            }
        }
        endColumn = max(startCol, min(endColumn, trimmedLength))
    }

    let limit = max(endColumn, startCol)
    var result = ""
    var index = startCol
    while index < limit {
        let code = logicalCode(index)
        let cellWidth = width(index)
        if index > 0 && code == 0 && width(index - 1) == 2 {
            index += 1
            continue
        }

        result.append(contentsOf: text(index))
        if cellWidth == 2 {
            let nextIndex = index + 1
            if nextIndex < limit && logicalCode(nextIndex) == 0 {
                index += 2
                continue
            }
        }
        index += 1
    }
    return result
}
