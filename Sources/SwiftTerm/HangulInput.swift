import Foundation

enum HangulInput {
    struct ResyllabificationEdit: Equatable {
        let charactersToDelete: Int
        let textToInsert: String
    }

    /// Tracks the edit sequence emitted by the Korean iOS keyboard when it
    /// resyllabifies a final consonant. UIKit deletes the syllable and, when
    /// available, the preceding character. It then reinserts that preceding
    /// character and commits the already-composed following syllable. At the
    /// start of the input buffer there is no prefix reinsert step.
    struct ResyllabificationTransaction {
        enum InsertionResult: Equatable {
            case noMatch
            case prefixReinserted
            case replacement(ResyllabificationEdit)
        }

        private enum State {
            case awaitingPrefix(prefix: Character, base: Character)
            case awaitingFollowingSyllable(prefix: Character?, base: Character)
        }

        private var state: State?

        mutating func begin(deletedText: String) {
            state = nil

            guard let base = deletedText.last,
                  resyllabificationPrefix(base: base) != nil else {
                return
            }

            switch deletedText.count {
            case 1:
                // At the start of the input buffer UIKit has no preceding
                // character to preserve, so it deletes only the base syllable
                // and commits the following syllable immediately.
                state = .awaitingFollowingSyllable(prefix: nil, base: base)
            case 2:
                guard let prefix = deletedText.first else { return }
                state = .awaitingPrefix(prefix: prefix, base: base)
            default:
                break
            }
        }

        /// Advances the transaction for an insertion. A reinserted prefix is
        /// committed unchanged. The final composed syllable produces an edit
        /// that either replaces that prefix or inserts directly at buffer start.
        mutating func consumeInsertion(_ text: String) -> InsertionResult {
            guard let state else { return .noMatch }

            switch state {
            case let .awaitingPrefix(prefix, base):
                self.state = nil
                guard text == String(prefix) else { return .noMatch }
                self.state = .awaitingFollowingSyllable(prefix: prefix, base: base)
                return .prefixReinserted

            case let .awaitingFollowingSyllable(prefix, base):
                self.state = nil
                guard text.count == 1,
                      let followingSyllable = text.first,
                      let edit = resyllabificationEdit(base: base, followingSyllable: followingSyllable) else {
                    return .noMatch
                }
                return .replacement(ResyllabificationEdit(
                    charactersToDelete: prefix == nil ? 0 : 1,
                    textToInsert: (prefix.map { String($0) } ?? "") + edit.textToInsert))
            }
        }

        mutating func reset() {
            state = nil
        }
    }

    private static let syllableBase = 0xAC00
    private static let syllableEnd = 0xD7A3
    private static let vowelCount = 21
    private static let finalCount = 28

    static let finalIndexByJamo: [Character: Int] = [
        "ㄱ": 1, "ㄲ": 2, "ㄳ": 3,
        "ㄴ": 4, "ㄵ": 5, "ㄶ": 6,
        "ㄷ": 7,
        "ㄹ": 8, "ㄺ": 9, "ㄻ": 10, "ㄼ": 11, "ㄽ": 12, "ㄾ": 13, "ㄿ": 14, "ㅀ": 15,
        "ㅁ": 16,
        "ㅂ": 17, "ㅄ": 18,
        "ㅅ": 19, "ㅆ": 20,
        "ㅇ": 21,
        "ㅈ": 22,
        "ㅊ": 23,
        "ㅋ": 24,
        "ㅌ": 25,
        "ㅍ": 26,
        "ㅎ": 27
    ]

    static let vowelIndexByJamo: [Character: Int] = [
        "ㅏ": 0, "ㅐ": 1, "ㅑ": 2, "ㅒ": 3,
        "ㅓ": 4, "ㅔ": 5, "ㅕ": 6, "ㅖ": 7,
        "ㅗ": 8, "ㅘ": 9, "ㅙ": 10, "ㅚ": 11,
        "ㅛ": 12,
        "ㅜ": 13, "ㅝ": 14, "ㅞ": 15, "ㅟ": 16,
        "ㅠ": 17,
        "ㅡ": 18, "ㅢ": 19,
        "ㅣ": 20
    ]

    static func composeSyllable(leadingIndex: Int, vowelIndex: Int, finalIndex: Int = 0) -> Character? {
        guard leadingIndex >= 0 && leadingIndex < 19 else { return nil }
        guard vowelIndex >= 0 && vowelIndex < vowelCount else { return nil }
        guard finalIndex >= 0 && finalIndex < finalCount else { return nil }
        let scalarValue = syllableBase + (leadingIndex * vowelCount + vowelIndex) * finalCount + finalIndex
        guard let scalar = UnicodeScalar(scalarValue) else { return nil }
        return Character(scalar)
    }

    static func composeSyllable(base: Character, finalIndex: Int) -> Character? {
        guard finalIndex > 0 && finalIndex < finalCount else { return nil }
        guard let components = syllableComponents(of: base) else { return nil }
        guard components.finalIndex == 0 else { return nil }
        return composeSyllable(
            leadingIndex: components.leadingIndex,
            vowelIndex: components.vowelIndex,
            finalIndex: finalIndex)
    }

    static func resyllabifyFinalConsonant(base: Character, followingVowel: Character) -> String? {
        resyllabificationEdit(base: base, followingVowel: followingVowel)?.textToInsert
    }

    static func resyllabificationEdit(base: Character, followingVowel: Character) -> ResyllabificationEdit? {
        guard let prefix = resyllabificationPrefix(base: base) else { return nil }
        guard let followingVowelIndex = vowelIndexByJamo[followingVowel] else { return nil }
        guard let next = composeSyllable(
            leadingIndex: prefix.movedLeadingIndex,
            vowelIndex: followingVowelIndex) else { return nil }
        return ResyllabificationEdit(
            charactersToDelete: 1,
            textToInsert: String(prefix.previous) + String(next))
    }

    /// Returns the same edit when UIKit has already composed the following
    /// syllable. The leading consonant must be the consonant moved from the
    /// final position of `base`.
    static func resyllabificationEdit(base: Character, followingSyllable: Character) -> ResyllabificationEdit? {
        guard let prefix = resyllabificationPrefix(base: base),
              let followingComponents = syllableComponents(of: followingSyllable),
              followingComponents.leadingIndex == prefix.movedLeadingIndex else {
            return nil
        }

        return ResyllabificationEdit(
            charactersToDelete: 1,
            textToInsert: String(prefix.previous) + String(followingSyllable))
    }

    private static func syllableComponents(of character: Character) -> (leadingIndex: Int, vowelIndex: Int, finalIndex: Int)? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return nil }
        let scalarValue = Int(scalar.value)
        guard scalarValue >= syllableBase && scalarValue <= syllableEnd else { return nil }
        let syllableIndex = scalarValue - syllableBase
        return (
            leadingIndex: syllableIndex / (vowelCount * finalCount),
            vowelIndex: (syllableIndex % (vowelCount * finalCount)) / finalCount,
            finalIndex: syllableIndex % finalCount)
    }

    private static func resyllabificationPrefix(base: Character) -> (previous: Character, movedLeadingIndex: Int)? {
        guard let components = syllableComponents(of: base),
              components.finalIndex > 0,
              let split = splitFinalForFollowingVowel(components.finalIndex),
              let previous = composeSyllable(
                  leadingIndex: components.leadingIndex,
                  vowelIndex: components.vowelIndex,
                  finalIndex: split.remainingFinalIndex) else {
            return nil
        }

        return (previous, split.movedLeadingIndex)
    }

    private static func splitFinalForFollowingVowel(_ finalIndex: Int) -> (remainingFinalIndex: Int, movedLeadingIndex: Int)? {
        switch finalIndex {
        case 1: return (0, 0)   // ㄱ
        case 2: return (0, 1)   // ㄲ
        case 3: return (1, 9)   // ㄳ -> ㄱ + ㅅ
        case 4: return (0, 2)   // ㄴ
        case 5: return (4, 12)  // ㄵ -> ㄴ + ㅈ
        case 6: return (4, 18)  // ㄶ -> ㄴ + ㅎ
        case 7: return (0, 3)   // ㄷ
        case 8: return (0, 5)   // ㄹ
        case 9: return (8, 0)   // ㄺ -> ㄹ + ㄱ
        case 10: return (8, 6)  // ㄻ -> ㄹ + ㅁ
        case 11: return (8, 7)  // ㄼ -> ㄹ + ㅂ
        case 12: return (8, 9)  // ㄽ -> ㄹ + ㅅ
        case 13: return (8, 16) // ㄾ -> ㄹ + ㅌ
        case 14: return (8, 17) // ㄿ -> ㄹ + ㅍ
        case 15: return (8, 18) // ㅀ -> ㄹ + ㅎ
        case 16: return (0, 6)  // ㅁ
        case 17: return (0, 7)  // ㅂ
        case 18: return (17, 9) // ㅄ -> ㅂ + ㅅ
        case 19: return (0, 9)  // ㅅ
        case 20: return (0, 10) // ㅆ
        case 21: return (0, 11) // ㅇ
        case 22: return (0, 12) // ㅈ
        case 23: return (0, 14) // ㅊ
        case 24: return (0, 15) // ㅋ
        case 25: return (0, 16) // ㅌ
        case 26: return (0, 17) // ㅍ
        case 27: return (0, 18) // ㅎ
        default: return nil
        }
    }
}
