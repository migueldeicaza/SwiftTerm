//
//  Position.swift
//  
//
//  Created by Miguel de Icaza on 3/13/20.
//

import Foundation

/// Represents a column and row
public struct Position: Equatable, CustomDebugStringConvertible {
    public var col, row: Int
    
    public init (col: Int, row: Int) {
        self.col = col
        self.row = row
    }
    
    public enum compareResult {
        case before
        case after
        case equal
    }
    
    // Compares two positions for ordering
    // -1 a comes before b
    //  1 a comes after b
    //  0 a and b are the same
    public static func compare (_ a: Position, _ b: Position) -> compareResult
    {
        if a.row < b.row { return .before }
        if a.row > b.row { return .after }
        // a and b are on the same row, compare columns
        if a.col < b.col { return .before }
        if a.col > b.col { return .after }
        return .equal
    }
    
    public var debugDescription: String {
        get {
            "col=\(col) row=\(row)"
        }
    }
    
    func toScreenCoordinate (from: Buffer) -> Position? {
        if row < from.yDisp {
            return nil
        }
        return Position (col: col, row: row-from.yDisp)
    }
}

