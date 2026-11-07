import XCTest
@testable import SwiftTerm

final class HangulInputTests: XCTestCase {
    func testComposesCompoundVowels() {
        let cases: [(Character, Character, Character)] = [
            ("고", "ㅏ", "과"), ("고", "ㅐ", "괘"), ("도", "ㅣ", "되"),
            ("구", "ㅓ", "궈"), ("구", "ㅔ", "궤"), ("구", "ㅣ", "귀"), ("그", "ㅣ", "긔")
        ]
        for (base, jamo, expected) in cases {
            XCTAssertEqual(HangulInput.composeSyllable(base: base, followingJamo: jamo), expected)
        }
    }

    func testComposesAllCompoundFinals() {
        let cases: [(Character, Character, Character)] = [
            ("넉", "ㅅ", "넋"), ("안", "ㅈ", "앉"), ("안", "ㅎ", "않"),
            ("달", "ㄱ", "닭"), ("올", "ㅁ", "옮"), ("짤", "ㅂ", "짧"),
            ("골", "ㅅ", "곬"), ("할", "ㅌ", "핥"), ("을", "ㅍ", "읊"),
            ("실", "ㅎ", "싫"), ("갑", "ㅅ", "값")
        ]
        for (base, jamo, expected) in cases {
            XCTAssertEqual(HangulInput.composeSyllable(base: base, followingJamo: jamo), expected)
        }
    }

    func testCompositionPreservesEverySupportedFinal() {
        let cases: [(Character, Character)] = [
            ("ㄱ", "각"), ("ㄲ", "갂"), ("ㄳ", "갃"),
            ("ㄴ", "간"), ("ㄵ", "갅"), ("ㄶ", "갆"), ("ㄷ", "갇"),
            ("ㄹ", "갈"), ("ㄺ", "갉"), ("ㄻ", "갊"), ("ㄼ", "갋"),
            ("ㄽ", "갌"), ("ㄾ", "갍"), ("ㄿ", "갎"), ("ㅀ", "갏"),
            ("ㅁ", "감"), ("ㅂ", "갑"), ("ㅄ", "값"),
            ("ㅅ", "갓"), ("ㅆ", "갔"), ("ㅇ", "강"),
            ("ㅈ", "갖"), ("ㅊ", "갗"), ("ㅋ", "갘"),
            ("ㅌ", "같"), ("ㅍ", "갚"), ("ㅎ", "갛")
        ]
        for (jamo, expected) in cases {
            XCTAssertEqual(HangulInput.composeSyllable(base: "가", followingJamo: jamo), expected)
        }
    }

    func testCompositionRejectsUnrelatedCharactersAndInvalidCombinations() {
        let cases: [(Character, Character)] = [
            ("A", "ㅣ"), ("ㄷ", "ㅣ"), ("도", "x"), ("도", "ㅓ"),
            ("돈", "ㅣ"), ("안", "ㄱ"), ("않", "ㅎ"), ("되", "ㅣ"), ("값", "ㅅ")
        ]
        for (base, jamo) in cases {
            XCTAssertNil(HangulInput.composeSyllable(base: base, followingJamo: jamo))
        }
    }

    func testNewCompoundFinalCanResyllabify() {
        let composed = HangulInput.composeSyllable(base: "안", followingJamo: "ㅎ")!
        XCTAssertEqual(HangulInput.resyllabifyFinalConsonant(base: composed, followingVowel: "ㅏ"), "안하")
    }

    func testComposesTrailingFinalConsonant() {
        XCTAssertEqual(
            HangulInput.composeSyllable(base: "하", followingJamo: "ㅅ"),
            "핫")
    }

    func testResyllabifiesFinalConsonantBeforeFollowingVowel() {
        XCTAssertEqual(
            HangulInput.resyllabifyFinalConsonant(base: "핫", followingVowel: "ㅔ"),
            "하세")
    }

    func testResyllabificationPreservesPreviousSyllableInBuffer() {
        var text = "안녕핫"
        let last = text.removeLast()
        let edit = HangulInput.resyllabificationEdit(base: last, followingVowel: "ㅔ")

        XCTAssertEqual(edit?.charactersToDelete, 1)
        XCTAssertEqual(edit?.textToInsert, "하세")
        text.append(contentsOf: edit!.textToInsert)
        XCTAssertEqual(text, "안녕하세")
    }

    func testResyllabifiesFinalIeungBeforeFollowingVowel() {
        XCTAssertEqual(
            HangulInput.resyllabifyFinalConsonant(base: "셍", followingVowel: "ㅛ"),
            "세요")
    }

    func testResyllabifiesCompoundFinalConsonantBeforeFollowingVowel() {
        XCTAssertEqual(
            HangulInput.resyllabifyFinalConsonant(base: "값", followingVowel: "ㅏ"),
            "갑사")
    }

    func testResyllabifiesAllCompoundFinals() {
        let cases: [(Character, Character, String)] = [
            ("넋", "ㅏ", "넉사"), ("앉", "ㅏ", "안자"), ("않", "ㅏ", "안하"),
            ("닭", "ㅏ", "달가"), ("옮", "ㅏ", "올마"), ("짧", "ㅏ", "짤바"),
            ("곬", "ㅏ", "골사"),
            ("핥", "ㅏ", "할타"), ("읊", "ㅓ", "을퍼"), ("싫", "ㅓ", "실허"),
            ("값", "ㅣ", "갑시"),
        ]

        for (base, vowel, expected) in cases {
            let edit = HangulInput.resyllabificationEdit(base: base, followingVowel: vowel)
            XCTAssertEqual(edit?.textToInsert, expected, "\(base)+\(vowel)")
            XCTAssertEqual(edit?.charactersToDelete, 1)
        }
    }

    func testResyllabificationTransactionHandlesUIKitDeleteAndReinsertSequence() {
        var transaction = HangulInput.ResyllabificationTransaction()
        transaction.begin(deletedText: " 핫")

        XCTAssertEqual(transaction.consumeInsertion(" "), .prefixReinserted)
        XCTAssertEqual(
            transaction.consumeInsertion("세"),
            .replacement(.init(charactersToDelete: 1, textToInsert: " 하세")))
    }

    func testResyllabificationTransactionHandlesStartOfInputBuffer() {
        var transaction = HangulInput.ResyllabificationTransaction()
        transaction.begin(deletedText: "핫")

        XCTAssertEqual(
            transaction.consumeInsertion("세"),
            .replacement(.init(charactersToDelete: 0, textToInsert: "하세")))
    }

    func testResyllabificationTransactionHandlesCompoundFinals() {
        var transaction = HangulInput.ResyllabificationTransaction()
        transaction.begin(deletedText: " 값")

        XCTAssertEqual(transaction.consumeInsertion(" "), .prefixReinserted)
        XCTAssertEqual(
            transaction.consumeInsertion("사"),
            .replacement(.init(charactersToDelete: 1, textToInsert: " 갑사")))
    }

    func testResyllabificationTransactionExpiresOnUnexpectedInsertion() {
        var transaction = HangulInput.ResyllabificationTransaction()
        transaction.begin(deletedText: " 핫")

        XCTAssertEqual(transaction.consumeInsertion("x"), .noMatch)
        XCTAssertEqual(transaction.consumeInsertion("세"), .noMatch)
    }

    func testResyllabificationTransactionIgnoresSyllablesWithoutFinals() {
        var transaction = HangulInput.ResyllabificationTransaction()
        transaction.begin(deletedText: " 하")

        XCTAssertEqual(transaction.consumeInsertion(" "), .noMatch)
    }

    func testComposedFollowingSyllableMustStartWithMovedFinalConsonant() {
        XCTAssertNil(
            HangulInput.resyllabificationEdit(base: "핫", followingSyllable: "아"))
    }

    func testDoesNotResyllabifySyllableWithoutFinalConsonant() {
        XCTAssertNil(HangulInput.resyllabifyFinalConsonant(base: "하", followingVowel: "ㅔ"))
    }
}
