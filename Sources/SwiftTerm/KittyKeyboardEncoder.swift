//
//  KittyKeyboardEncoder.swift
//  SwiftTerm
//

import Foundation

enum KittyKey {
    case unicode(UInt32)
    case functional(KittyFunctionalKey)
    case none
}

enum KittyFunctionalKey {
    case escape
    case enter
    case tab
    case backspace
    case insert
    case delete
    case up
    case down
    case left
    case right
    case home
    case end
    case pageUp
    case pageDown
    case f1
    case f2
    case f3
    case f4
    case f5
    case f6
    case f7
    case f8
    case f9
    case f10
    case f11
    case f12
    case f13
    case f14
    case f15
    case f16
    case f17
    case f18
    case f19
    case f20
    case f21
    case f22
    case f23
    case f24
    case f25
    case f26
    case f27
    case f28
    case f29
    case f30
    case f31
    case f32
    case f33
    case f34
    case f35
    case menu
    case capsLock
    case scrollLock
    case numLock
    case printScreen
    case pause
    case keypad0
    case keypad1
    case keypad2
    case keypad3
    case keypad4
    case keypad5
    case keypad6
    case keypad7
    case keypad8
    case keypad9
    case keypadDecimal
    case keypadDivide
    case keypadMultiply
    case keypadSubtract
    case keypadAdd
    case keypadEnter
    case keypadEqual
    case keypadSeparator
    case keypadLeft
    case keypadRight
    case keypadUp
    case keypadDown
    case keypadPageUp
    case keypadPageDown
    case keypadHome
    case keypadEnd
    case keypadInsert
    case keypadDelete
    case keypadBegin
    case mediaPlay
    case mediaPause
    case mediaPlayPause
    case mediaReverse
    case mediaStop
    case mediaFastForward
    case mediaRewind
    case mediaTrackNext
    case mediaTrackPrevious
    case mediaRecord
    case volumeDown
    case volumeUp
    case volumeMute
    case leftShift
    case leftControl
    case leftAlt
    case leftSuper
    case leftHyper
    case leftMeta
    case rightShift
    case rightControl
    case rightAlt
    case rightSuper
    case rightHyper
    case rightMeta
    case isoLevel3Shift
    case isoLevel5Shift
}

struct KittyKeyEvent {
    var key: KittyKey
    var modifiers: KittyKeyboardModifiers
    var eventType: KittyKeyboardEventType
    var text: String?
    var shiftedKey: UnicodeScalar?
    var baseLayoutKey: UnicodeScalar?
}

struct KittyKeyboardEncoder {
    let flags: KittyKeyboardFlags
    let applicationCursor: Bool
    let backspaceSendsControlH: Bool

    func encode(_ event: KittyKeyEvent) -> [UInt8]? {
        let wantsAllKeys = flags.contains(.reportAllKeys)
        let wantsDisambiguate = flags.contains(.disambiguate) || wantsAllKeys
        let wantsEvents = flags.contains(.reportEvents)
        let wantsAlternates = flags.contains(.reportAlternates)
        let wantsText = wantsAllKeys && flags.contains(.reportText)

        if event.eventType != .press && !wantsEvents {
            return nil
        }
        if event.eventType == .release,
           wantsEvents,
           !wantsAllKeys,
           case let .functional(key) = event.key,
           key == .enter || key == .tab || key == .backspace {
            return nil
        }

        if wantsAllKeys {
            switch event.key {
            case .functional(let key):
                if key == .enter || key == .tab || key == .backspace {
                    return encodeCsiU(event: event,
                                      overrideKeyCode: functionalUnicodeCodepoint(for: key),
                                      includeText: wantsText,
                                      includeAlternates: wantsAlternates,
                                      includeEventType: wantsEvents,
                                      includeLocks: true)
                }
                return encodeFunctionalKey(key,
                                           event: event,
                                           disambiguate: true,
                                           includeEventType: wantsEvents,
                                           includeAlternates: wantsAlternates,
                                           includeLocks: true)
            case .unicode, .none:
                return encodeCsiU(event: event,
                                  includeText: wantsText,
                                  includeAlternates: wantsAlternates,
                                  includeEventType: wantsEvents,
                                  includeLocks: true)
            }
        }

        if let text = event.text, !text.isEmpty {
            let hasAltOrCtrl = event.modifiers.contains(.alt) || event.modifiers.contains(.ctrl)
            if !wantsDisambiguate || !hasAltOrCtrl {
                if event.eventType == .press {
                    return [UInt8](text.utf8)
                }
                return nil
            }
        }

        return encodeNonText(event: event, disambiguate: wantsDisambiguate, includeEventType: wantsEvents, includeAlternates: wantsAlternates)
    }

    private func encodeNonText(event: KittyKeyEvent,
                               disambiguate: Bool,
                               includeEventType: Bool,
                               includeAlternates: Bool) -> [UInt8]? {
        switch event.key {
        case .none:
            return encodeCsiU(event: event, includeText: false, includeAlternates: includeAlternates, includeEventType: includeEventType, includeLocks: false)
        case .unicode(let codepoint):
            if !disambiguate {
                if let legacy = legacyTextKeySequence(event: event) {
                    return legacy
                }
                var updated = event
                updated.text = nil
                return encodeCsiU(event: updated,
                                  includeText: false,
                                  includeAlternates: includeAlternates,
                                  includeEventType: includeEventType,
                                  includeLocks: false)
            }
            var updated = event
            updated.text = nil
            return encodeCsiU(event: updated, overrideKeyCode: Int(codepoint), includeText: false, includeAlternates: includeAlternates, includeEventType: includeEventType, includeLocks: false)
        case .functional(let key):
            return encodeFunctionalKey(key, event: event, disambiguate: disambiguate, includeEventType: includeEventType, includeAlternates: includeAlternates, includeLocks: false)
        }
    }

    private func encodeFunctionalKey(_ key: KittyFunctionalKey,
                                     event: KittyKeyEvent,
                                     disambiguate: Bool,
                                     includeEventType: Bool,
                                     includeAlternates: Bool,
                                     includeLocks: Bool) -> [UInt8]? {
        let modifiers = modifiersValue(for: event.modifiers, includeLocks: includeLocks)
        let includeType = includeEventType && event.eventType != .press
        let wantsModifiersField = modifiers != 0 || includeType

        switch key {
        case .escape:
            if disambiguate {
                return encodeCsiU(event: event, overrideKeyCode: 27, includeText: false, includeAlternates: includeAlternates, includeEventType: includeEventType, includeLocks: false)
            }
            return legacySpecialKeySequence(for: key, modifiers: event.modifiers, eventType: event.eventType)
        case .enter, .tab, .backspace:
            if disambiguate && wantsModifiersField {
                return encodeCsiU(event: event,
                                  overrideKeyCode: functionalUnicodeCodepoint(for: key),
                                  includeText: false,
                                  includeAlternates: includeAlternates,
                                  includeEventType: includeEventType,
                                  includeLocks: false)
            }
            return legacySpecialKeySequence(for: key, modifiers: event.modifiers, eventType: event.eventType)
        default:
            break
        }

        switch functionalEncoding(for: key) {
        case .csiLetter(let letter):
            if !disambiguate && !wantsModifiersField {
                if usesSs3InLegacy(key: key) {
                    return [ControlCodes.ESC, 0x4f, letter]
                }
                guard let scalar = UnicodeScalar(letter) else { return nil }
                return buildCsi(String(scalar))
            }
            guard let scalar = UnicodeScalar(letter) else { return nil }
            return buildCsiWithModifier(number: 1,
                                        modifiers: modifiers,
                                        eventType: includeType ? event.eventType : nil,
                                        terminator: scalar,
                                        omitDefaultNumber: true)
        case .csiTilde(let number):
            return buildCsiWithModifier(number: number, modifiers: modifiers, eventType: includeType ? event.eventType : nil, terminator: "~")
        case .csiU(let codepoint):
            var updated = event
            updated.text = nil
            return encodeCsiU(event: updated, overrideKeyCode: codepoint, includeText: false, includeAlternates: includeAlternates, includeEventType: includeEventType, includeLocks: false)
        }
    }

    private func encodeCsiU(event: KittyKeyEvent,
                            overrideKeyCode: Int? = nil,
                            includeText: Bool,
                            includeAlternates: Bool,
                            includeEventType: Bool,
                            includeLocks: Bool) -> [UInt8] {
        let keyCode: Int
        if let override = overrideKeyCode {
            keyCode = override
        } else {
            switch event.key {
            case .unicode(let codepoint):
                keyCode = Int(codepoint)
            case .functional(let key):
                keyCode = functionalUnicodeCodepoint(for: key) ?? 0
            case .none:
                keyCode = 0
            }
        }

        let modifiers = modifiersValue(for: event.modifiers, includeLocks: includeLocks)
        let includeType = includeEventType && event.eventType != .press
        let textCodepoints = includeText ? textCodepoints(from: event.text) : nil
        let includeModifiersField = includeType || modifiers != 0

        var body = "\(keyCode)"
        if includeAlternates {
            let shifted = event.modifiers.contains(.shift) ? event.shiftedKey : nil
            let base = event.baseLayoutKey
            if shifted != nil || base != nil {
                if let shifted {
                    body += ":\(shifted.value)"
                } else {
                    body += ":"
                }
                if let base {
                    body += ":\(base.value)"
                }
            }
        }

        if includeModifiersField {
            let modValue = modifiers + 1
            if includeType {
                body += ";\(modValue):\(event.eventType.rawValue)"
            } else {
                body += ";\(modValue)"
            }
        }

        if let textCodepoints, !textCodepoints.isEmpty {
            if !includeModifiersField {
                body += ";;"
            } else {
                body += ";"
            }
            body += textCodepoints.map(String.init).joined(separator: ":")
        }

        return buildCsi("\(body)u")
    }

    private func buildCsi(_ payload: String) -> [UInt8] {
        var bytes = [ControlCodes.ESC, 0x5b]
        bytes.append(contentsOf: payload.utf8)
        return bytes
    }

    private func buildCsiWithModifier(number: Int,
                                      modifiers: Int,
                                      eventType: KittyKeyboardEventType?,
                                      terminator: UnicodeScalar,
                                      omitDefaultNumber: Bool) -> [UInt8] {
        let includeField = modifiers != 0 || eventType != nil
        var payload = ""
        if !omitDefaultNumber || includeField || number != 1 {
            payload = "\(number)"
        }
        if includeField {
            let modValue = modifiers + 1
            if payload.isEmpty {
                payload = "\(number)"
            }
            if let eventType {
                payload += ";\(modValue):\(eventType.rawValue)"
            } else {
                payload += ";\(modValue)"
            }
        }
        payload.append(Character(terminator))
        return buildCsi(payload)
    }

    private func buildCsiWithModifier(number: Int,
                                      modifiers: Int,
                                      eventType: KittyKeyboardEventType?,
                                      terminator: String) -> [UInt8] {
        let includeField = modifiers != 0 || eventType != nil
        var payload = "\(number)"
        if includeField {
            let modValue = modifiers + 1
            if let eventType {
                payload += ";\(modValue):\(eventType.rawValue)"
            } else {
                payload += ";\(modValue)"
            }
        }
        payload.append(contentsOf: terminator)
        return buildCsi(payload)
    }

    private func modifiersValue(for modifiers: KittyKeyboardModifiers, includeLocks: Bool) -> Int {
        var filtered = modifiers
        if !includeLocks {
            filtered.remove([.capsLock, .numLock])
        }
        return filtered.rawValue
    }

    private func legacyTextKeySequence(event: KittyKeyEvent) -> [UInt8]? {
        if event.eventType != .press {
            return nil
        }
        guard case let .unicode(codepoint) = event.key,
              let scalar = UnicodeScalar(codepoint) else {
            return nil
        }

        var modifiers = event.modifiers
        modifiers.remove([.capsLock, .numLock])
        let legacyMask: KittyKeyboardModifiers = [.shift, .alt, .ctrl]
        if !modifiers.subtracting(legacyMask).isEmpty {
            return nil
        }
        if modifiers.contains(.ctrl) && modifiers.contains(.shift) {
            return nil
        }

        var output: [UInt8] = []
        if modifiers.contains(.alt) {
            output.append(ControlCodes.ESC)
        }

        if modifiers.contains(.ctrl),
           let mapped = legacyControlMapping(for: scalar) {
            output.append(mapped)
            return output
        }

        if let text = event.text, !text.isEmpty {
            output.append(contentsOf: text.utf8)
            return output
        }

        let outputScalar: UnicodeScalar?
        if modifiers.contains(.shift) {
            outputScalar = event.shiftedKey ?? event.text?.unicodeScalars.first ?? scalar
        } else {
            outputScalar = scalar
        }

        if let outputScalar {
            output.append(contentsOf: String(outputScalar).utf8)
        }
        return output
    }

    private func legacyControlMapping(for scalar: UnicodeScalar) -> UInt8? {
        let mapping: [UnicodeScalar: UInt8] = [
            " ": 0,
            "/": 31,
            "0": 48,
            "1": 49,
            "2": 0,
            "3": 27,
            "4": 28,
            "5": 29,
            "6": 30,
            "7": 31,
            "8": 127,
            "9": 57,
            "?": 127,
            "@": 0,
            "[": 27,
            "\\": 28,
            "]": 29,
            "^": 30,
            "_": 31,
            "a": 1,
            "b": 2,
            "c": 3,
            "d": 4,
            "e": 5,
            "f": 6,
            "g": 7,
            "h": 8,
            "i": 9,
            "j": 10,
            "k": 11,
            "l": 12,
            "m": 13,
            "n": 14,
            "o": 15,
            "p": 16,
            "q": 17,
            "r": 18,
            "s": 19,
            "t": 20,
            "u": 21,
            "v": 22,
            "w": 23,
            "x": 24,
            "y": 25,
            "z": 26,
            "~": 30
        ]
        if let lowerScalar = String(scalar).lowercased().unicodeScalars.first,
           let mapped = mapping[lowerScalar] {
            return mapped
        }
        return mapping[scalar]
    }

    private func legacySpecialKeySequence(for key: KittyFunctionalKey,
                                          modifiers: KittyKeyboardModifiers,
                                          eventType: KittyKeyboardEventType) -> [UInt8]? {
        if eventType != .press {
            return nil
        }
        let sequence: [UInt8]
        switch key {
        case .enter:
            sequence = [ControlCodes.CR]
        case .escape:
            sequence = [ControlCodes.ESC]
        case .backspace:
            let base: UInt8 = modifiers.contains(.ctrl) ? ControlCodes.BS : (backspaceSendsControlH ? ControlCodes.BS : ControlCodes.DEL)
            sequence = [base]
        case .tab:
            if modifiers.contains(.shift) {
                sequence = [ControlCodes.ESC, 0x5b, 0x5a]
            } else {
                sequence = [ControlCodes.HT]
            }
        default:
            return nil
        }
        if modifiers.contains(.alt) {
            return [ControlCodes.ESC] + sequence
        }
        return sequence
    }

    private func usesSs3InLegacy(key: KittyFunctionalKey) -> Bool {
        switch key {
        case .f1, .f2, .f3, .f4:
            return true
        case .up, .down, .left, .right, .home, .end:
            return applicationCursor
        default:
            return false
        }
    }

    private func textCodepoints(from text: String?) -> [Int]? {
        guard let text else { return nil }
        var codepoints: [Int] = []
        for scalar in text.unicodeScalars {
            if scalar.value < 0x20 || (scalar.value >= 0x7f && scalar.value <= 0x9f) {
                continue
            }
            codepoints.append(Int(scalar.value))
        }
        if codepoints.isEmpty {
            return nil
        }
        return codepoints
    }

    private enum FunctionalEncoding {
        case csiLetter(UInt8)
        case csiTilde(Int)
        case csiU(Int)
    }

    private func functionalEncoding(for key: KittyFunctionalKey) -> FunctionalEncoding {
        switch key {
        case .up:
            return .csiLetter(UInt8(ascii: "A"))
        case .down:
            return .csiLetter(UInt8(ascii: "B"))
        case .right:
            return .csiLetter(UInt8(ascii: "C"))
        case .left:
            return .csiLetter(UInt8(ascii: "D"))
        case .home:
            return .csiLetter(UInt8(ascii: "H"))
        case .end:
            return .csiLetter(UInt8(ascii: "F"))
        case .f1:
            return .csiLetter(UInt8(ascii: "P"))
        case .f2:
            return .csiLetter(UInt8(ascii: "Q"))
        case .f3:
            return .csiLetter(UInt8(ascii: "R"))
        case .f4:
            return .csiLetter(UInt8(ascii: "S"))
        case .keypadBegin:
            return .csiLetter(UInt8(ascii: "E"))
        case .insert:
            return .csiTilde(2)
        case .delete:
            return .csiTilde(3)
        case .pageUp:
            return .csiTilde(5)
        case .pageDown:
            return .csiTilde(6)
        case .f5:
            return .csiTilde(15)
        case .f6:
            return .csiTilde(17)
        case .f7:
            return .csiTilde(18)
        case .f8:
            return .csiTilde(19)
        case .f9:
            return .csiTilde(20)
        case .f10:
            return .csiTilde(21)
        case .f11:
            return .csiTilde(23)
        case .f12:
            return .csiTilde(24)
        case .menu:
            return .csiU(57363)
        case .f13:
            return .csiU(57376)
        case .f14:
            return .csiU(57377)
        case .f15:
            return .csiU(57378)
        case .f16:
            return .csiU(57379)
        case .f17:
            return .csiU(57380)
        case .f18:
            return .csiU(57381)
        case .f19:
            return .csiU(57382)
        case .f20:
            return .csiU(57383)
        case .f21:
            return .csiU(57384)
        case .f22:
            return .csiU(57385)
        case .f23:
            return .csiU(57386)
        case .f24:
            return .csiU(57387)
        case .f25:
            return .csiU(57388)
        case .f26:
            return .csiU(57389)
        case .f27:
            return .csiU(57390)
        case .f28:
            return .csiU(57391)
        case .f29:
            return .csiU(57392)
        case .f30:
            return .csiU(57393)
        case .f31:
            return .csiU(57394)
        case .f32:
            return .csiU(57395)
        case .f33:
            return .csiU(57396)
        case .f34:
            return .csiU(57397)
        case .f35:
            return .csiU(57398)
        case .capsLock:
            return .csiU(57358)
        case .scrollLock:
            return .csiU(57359)
        case .numLock:
            return .csiU(57360)
        case .printScreen:
            return .csiU(57361)
        case .pause:
            return .csiU(57362)
        case .keypad0:
            return .csiU(57399)
        case .keypad1:
            return .csiU(57400)
        case .keypad2:
            return .csiU(57401)
        case .keypad3:
            return .csiU(57402)
        case .keypad4:
            return .csiU(57403)
        case .keypad5:
            return .csiU(57404)
        case .keypad6:
            return .csiU(57405)
        case .keypad7:
            return .csiU(57406)
        case .keypad8:
            return .csiU(57407)
        case .keypad9:
            return .csiU(57408)
        case .keypadDecimal:
            return .csiU(57409)
        case .keypadDivide:
            return .csiU(57410)
        case .keypadMultiply:
            return .csiU(57411)
        case .keypadSubtract:
            return .csiU(57412)
        case .keypadAdd:
            return .csiU(57413)
        case .keypadEnter:
            return .csiU(57414)
        case .keypadEqual:
            return .csiU(57415)
        case .keypadSeparator:
            return .csiU(57416)
        case .keypadLeft:
            return .csiU(57417)
        case .keypadRight:
            return .csiU(57418)
        case .keypadUp:
            return .csiU(57419)
        case .keypadDown:
            return .csiU(57420)
        case .keypadPageUp:
            return .csiU(57421)
        case .keypadPageDown:
            return .csiU(57422)
        case .keypadHome:
            return .csiU(57423)
        case .keypadEnd:
            return .csiU(57424)
        case .keypadInsert:
            return .csiU(57425)
        case .keypadDelete:
            return .csiU(57426)
        case .mediaPlay:
            return .csiU(57428)
        case .mediaPause:
            return .csiU(57429)
        case .mediaPlayPause:
            return .csiU(57430)
        case .mediaReverse:
            return .csiU(57431)
        case .mediaStop:
            return .csiU(57432)
        case .mediaFastForward:
            return .csiU(57433)
        case .mediaRewind:
            return .csiU(57434)
        case .mediaTrackNext:
            return .csiU(57435)
        case .mediaTrackPrevious:
            return .csiU(57436)
        case .mediaRecord:
            return .csiU(57437)
        case .volumeDown:
            return .csiU(57438)
        case .volumeUp:
            return .csiU(57439)
        case .volumeMute:
            return .csiU(57440)
        case .leftShift:
            return .csiU(57441)
        case .leftControl:
            return .csiU(57442)
        case .leftAlt:
            return .csiU(57443)
        case .leftSuper:
            return .csiU(57444)
        case .leftHyper:
            return .csiU(57445)
        case .leftMeta:
            return .csiU(57446)
        case .rightShift:
            return .csiU(57447)
        case .rightControl:
            return .csiU(57448)
        case .rightAlt:
            return .csiU(57449)
        case .rightSuper:
            return .csiU(57450)
        case .rightHyper:
            return .csiU(57451)
        case .rightMeta:
            return .csiU(57452)
        case .isoLevel3Shift:
            return .csiU(57453)
        case .isoLevel5Shift:
            return .csiU(57454)
        case .escape, .enter, .tab, .backspace:
            return .csiU(0)
        }
    }

    private func functionalUnicodeCodepoint(for key: KittyFunctionalKey) -> Int? {
        switch key {
        case .escape:
            return 27
        case .enter:
            return 13
        case .tab:
            return 9
        case .backspace:
            return 127
        default:
            if case let .csiU(codepoint) = functionalEncoding(for: key) {
                return codepoint
            }
            return nil
        }
    }
}
