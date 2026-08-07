//
//  KittyKeyboardProtocol.swift
//  SwiftTerm
//
//  Implements state and shared types for the kitty keyboard protocol.
//

import Foundation

public struct KittyKeyboardFlags: OptionSet {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let disambiguate = KittyKeyboardFlags(rawValue: 1 << 0)
    public static let reportEvents = KittyKeyboardFlags(rawValue: 1 << 1)
    public static let reportAlternates = KittyKeyboardFlags(rawValue: 1 << 2)
    public static let reportAllKeys = KittyKeyboardFlags(rawValue: 1 << 3)
    public static let reportText = KittyKeyboardFlags(rawValue: 1 << 4)

    public static let knownMask: Int = [
        KittyKeyboardFlags.disambiguate,
        KittyKeyboardFlags.reportEvents,
        KittyKeyboardFlags.reportAlternates,
        KittyKeyboardFlags.reportAllKeys,
        KittyKeyboardFlags.reportText
    ].reduce(0) { $0 | $1.rawValue }
}

public enum KittyKeyboardEventType: Int {
    case press = 1
    case repeatPress = 2
    case release = 3
}

public struct KittyKeyboardModifiers: OptionSet {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let shift = KittyKeyboardModifiers(rawValue: 1 << 0)
    public static let alt = KittyKeyboardModifiers(rawValue: 1 << 1)
    public static let ctrl = KittyKeyboardModifiers(rawValue: 1 << 2)
    public static let `super` = KittyKeyboardModifiers(rawValue: 1 << 3)
    public static let hyper = KittyKeyboardModifiers(rawValue: 1 << 4)
    public static let meta = KittyKeyboardModifiers(rawValue: 1 << 5)
    public static let capsLock = KittyKeyboardModifiers(rawValue: 1 << 6)
    public static let numLock = KittyKeyboardModifiers(rawValue: 1 << 7)
}
