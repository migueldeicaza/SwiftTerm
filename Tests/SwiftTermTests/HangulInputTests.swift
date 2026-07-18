import XCTest
@testable import SwiftTerm

final class HangulInputTests: XCTestCase {
    func testComposesTrailingFinalConsonant() {
        XCTAssertEqual(
            HangulInput.composeSyllable(base: "하", finalIndex: HangulInput.finalIndexByJamo["ㅅ"]!),
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
