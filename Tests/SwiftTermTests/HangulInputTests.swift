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

    func testDoesNotResyllabifySyllableWithoutFinalConsonant() {
        XCTAssertNil(HangulInput.resyllabifyFinalConsonant(base: "하", followingVowel: "ㅔ"))
    }
}
