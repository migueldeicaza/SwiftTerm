import Foundation
import Testing
@testable import SwiftTerm

@Suite("OSC 7501 program status")
struct ProgramStatusTests {
    private final class Delegate: TerminalDelegate {
        var output: [UInt8] = []
        var updates: [[TerminalProgramStatus]] = []
        func send(source: Terminal, data: ArraySlice<UInt8>) { output.append(contentsOf: data) }
        func programStatusChanged(source: Terminal, records: [TerminalProgramStatus]) {
            updates.append(records)
        }
    }

    private func report(_ body: String, terminator: String = "\u{1b}\\") -> String {
        "\u{1b}]7501;" + body + terminator
    }

    private func base64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    @Test func detectionRepliesWithoutChangingRecords() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        for terminator in ["\u{1b}\\", "\u{7}"] {
            terminal.feed(text: report("?", terminator: terminator))
        }
        #expect(delegate.output == Array((report("?") + report("?", terminator: "\u{7}")).utf8))
        #expect(terminal.programStatusRecords.isEmpty)
        #expect(delegate.updates.isEmpty)
    }

    @Test func detectionPreservesTerminatorsAtEveryInputSplit() {
        let prefix = Array("\u{1b}]7501;?".utf8)
        let framing: [(request: [UInt8], reply: [UInt8])] = [
            ([0x1b, 0x5c], [0x1b, 0x5c]),
            ([0x07], [0x07]),
            ([0x9c], [0x1b, 0x5c])
        ]
        for frame in framing {
            let bytes = prefix + frame.request
            for split in 0...bytes.count {
                let delegate = Delegate()
                let terminal = Terminal(delegate: delegate)
                terminal.feed(text: report("state=blocked:id=build:kind=permission:app=cargo"))
                let original = terminal.programStatusRecords
                terminal.feed(buffer: bytes[..<split])
                if split < bytes.count { #expect(delegate.output.isEmpty) }
                terminal.feed(buffer: bytes[split...])
                #expect(delegate.output == prefix + frame.reply)
                #expect(terminal.programStatusRecords == original)
                #expect(delegate.updates == [original])
            }
        }
    }

    @Test func reportsReplaceEveryFieldAndDecodeUnicode() throws {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.feed(text: report("state=blocked:kind=permission:progress=35:app=deploy:title=\(base64("EU West")):msg=\(base64("Approve deployment? 🚀").replacingOccurrences(of: "=", with: ""))"))
        let first = try #require(terminal.programStatus())
        #expect(first.id == "")
        #expect(first.state == .blocked && first.kind == .permission && first.progress == 35)
        #expect(first.title == "EU West" && first.message == "Approve deployment? 🚀")
        #expect(first.app == "deploy" && first.effectiveApp == "deploy")
        terminal.feed(text: report("state=idle"))
        let second = try #require(terminal.programStatus())
        #expect(second.state == .idle)
        #expect(second.kind == nil && second.progress == nil && second.app == nil)
        #expect(second.effectiveApp == nil && second.title == nil && second.message == nil)
        #expect(delegate.updates.count == 2)
        #expect(delegate.updates.first?.first == first)
    }

    @Test func malformedPairsUnknownKeysAndRepeatedKeys() throws {
        let terminal = Terminal(delegate: Delegate())
        terminal.feed(text: report("bad:=empty:UNKNOWN=ignored:future=yes:state=error: state \t=\t working :msg=bad!:msg=\(base64("Ready")):progress=30:progress=40:app=first:app=last"))
        let record = try #require(terminal.programStatus())
        #expect(record.state == .working && record.progress == 40 && record.app == "last")
        #expect(record.message == "Ready")
        terminal.feed(text: report("state=done:state=future"))
        #expect(terminal.programStatus() == record)
        terminal.feed(text: report("app=absent-state"))
        #expect(terminal.programStatus() == record)
    }

    @Test func optionalValuesApplyOnlyToTheirStates() throws {
        let terminal = Terminal(delegate: Delegate())
        for state in ["idle", "done", "error"] {
            terminal.feed(text: report("state=\(state):kind=permission:progress=50"))
            let record = try #require(terminal.programStatus())
            #expect(record.kind == nil && record.progress == nil)
        }
        for value in ["", "-1", "+1", "101", "1.0", "99999999999999999999999999"] {
            terminal.feed(text: report("state=blocked:kind=unknown:progress=\(value):app=bad/name"))
            let record = try #require(terminal.programStatus())
            #expect(record.kind == nil && record.progress == nil && record.app == nil)
        }
        for kind in ["permission", "question", "auth"] {
            terminal.feed(text: report("state=blocked:kind=\(kind):progress=100"))
            #expect(terminal.programStatus()?.kind?.rawValue == kind)
            #expect(terminal.programStatus()?.progress == 100)
        }
    }

    @Test func hierarchyInheritsFromTheNearestExistingAncestor() {
        let terminal = Terminal(delegate: Delegate())
        terminal.feed(text: report("state=idle:app=root"))
        terminal.feed(text: report("state=blocked:id=build/test/unit"))
        #expect(terminal.programStatus(id: "build/test/unit")?.effectiveApp == "root")
        #expect(terminal.programStatus(id: "build/test/unit")?.app == nil)
        terminal.feed(text: report("state=working:id=build:app=cargo"))
        #expect(terminal.programStatus(id: "build/test/unit")?.effectiveApp == "cargo")
        terminal.feed(text: report("state=done:id=build/test:app=tester"))
        #expect(terminal.programStatus(id: "build/test/unit")?.effectiveApp == "tester")
        terminal.feed(text: report("state=done:id=build/test"))
        #expect(terminal.programStatus(id: "build/test/unit")?.effectiveApp == "cargo")
        terminal.feed(text: report("state=done:id=builder"))
        terminal.feed(text: report("state=clear:id=build"))
        #expect(terminal.programStatusRecords.map(\.id) == ["", "builder"])
        terminal.feed(text: report("state=clear"))
        #expect(terminal.programStatusRecords.isEmpty)
    }

    @Test func invalidIdsNeverOverwriteRoot() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.feed(text: report("state=done:app=keep"))
        let original = terminal.programStatusRecords
        for id in ["", "/", "/build", "build/", "build//test", "bad,name", "bad=name", "bad!", "bad name", "🚀",
                   String(repeating: "a", count: 33), "a/b/c/d/e/f/g/h/i",
                   Array(repeating: String(repeating: "a", count: 32), count: 4).joined(separator: "/")] {
            terminal.feed(text: report("state=working:id=\(id)"))
            terminal.feed(text: report("state=clear:id=\(id)"))
            #expect(terminal.programStatusRecords == original)
        }
        #expect(delegate.updates.count == 1)
    }

    @Test func invalidTextDiscardsTheWholeReportIncludingClear() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.feed(text: report("state=done:msg=\(base64("Keep"))"))
        let original = terminal.programStatusRecords
        let invalid = ["a", "YQ=", "YQ===", "Y=Q=", "YR==", "____", "----", "wA==", "/w=="]
            + ["\u{0}", "\t", "\n", "\u{1b}", "\u{7f}", "\u{80}", "\u{9f}"].map(base64)
        for text in invalid {
            for key in ["msg", "title"] {
                terminal.feed(text: report("state=clear:\(key)=\(text):\(key)=\(base64("Valid"))"))
                #expect(terminal.programStatusRecords == original)
            }
        }
        #expect(delegate.updates.count == 1)
    }

    @Test func eachFieldLimitIsCheckedBeforeAnyRecordChanges() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.feed(text: report("state=done"))
        let original = terminal.programStatusRecords
        let pairs = [
            "\(String(repeating: "k", count: 17))=x",
            "app=\(String(repeating: "a", count: 33))",
            "msg=\(base64(String(repeating: "m", count: 2049)))",
            "msg=\(String(repeating: "A", count: 2733))",
            "title=\(base64(String(repeating: "t", count: 193)))"
        ]
        for pair in pairs {
            terminal.feed(text: report("state=clear:\(pair):app=valid:msg=:title="))
            #expect(terminal.programStatusRecords == original)
        }
        terminal.feed(text: report("state=working:app=\(String(repeating: "a", count: 32)):title=\(base64(String(repeating: "t", count: 192))):msg=\(base64(String(repeating: "m", count: 2048)))"))
        #expect(terminal.programStatus()?.message?.utf8.count == 2048)
        #expect(terminal.programStatus()?.title?.utf8.count == 192)
    }

    @Test func sequenceLimitBoundsStorageAndRecovers() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        let parser = EscapeSequenceParser()
        let oversized = Array(("\u{1b}]7501;state=working:future=" + String(repeating: "x", count: 20_000)).utf8)
        parser.parse(data: oversized[...], terminal)
        #expect(parser._osc.count <= EscapeSequenceParser.maximumProgramStatusOscBytes)
        #expect(parser._oscLimitExceeded)
        let recovery = Array(("\u{1b}\\" + report("state=done")).utf8)
        parser.parse(data: recovery[...], terminal)
        #expect(terminal.programStatus()?.state == .done)
        let original = terminal.programStatusRecords
        terminal.feed(text: report("state=clear:" + String(repeating: "\t", count: 4100)))
        #expect(terminal.programStatusRecords == original)
        terminal.feed(text: "\u{1b}]" + String(repeating: "\u{0}", count: 5000) + "7501;state=clear\u{7}")
        #expect(terminal.programStatusRecords == original)
        #expect(delegate.updates.count == 1)
    }

    @Test func oversizedStatusEndsAtC1StAndKeepsFollowingText() {
        let prefix = Array("\u{1b}]7501;state=working:future=".utf8)
        let tails: [[UInt8]] = [[], [0xc3, 0x9c], [0xe2, 0x9c, 0x93], [0xf0, 0x9c, 0x80, 0x80]]
        for discardedTail in tails {
            let payload = prefix + Array(repeating: UInt8(ascii: "x"), count: 4100)
            let discarded = payload + discardedTail + Array("DISCARD".utf8)
            let input = discarded + [0x9c] + Array("VISIBLE".utf8)
            let splits = [0, 4092, 4093, payload.count, payload.count + 1,
                          discarded.count, discarded.count + 1, input.count]
            for split in splits {
                let delegate = Delegate()
                let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 2))
                terminal.silentLog = true
                terminal.feed(text: report("state=done"))
                let original = terminal.programStatusRecords
                terminal.feed(buffer: input[..<split])
                terminal.feed(buffer: input[split...])
                #expect(terminal.programStatusRecords == original)
                #expect(delegate.updates.count == 1)
                #expect(String(decoding: terminal.getBufferAsData(), as: UTF8.self).hasPrefix("VISIBLE\n"))
                terminal.feed(text: report("state=idle"))
                #expect(terminal.programStatus()?.state == .idle)
            }
        }
    }

    @Test func completeTerminatorsAndEveryInputSplit() {
        for terminator in ["\u{1b}\\", "\u{7}"] {
            let bytes = Array(report("state=working:msg=\(base64("Split 🚀"))", terminator: terminator).utf8)
            for split in 0...bytes.count {
                let delegate = Delegate()
                let terminal = Terminal(delegate: delegate)
                terminal.feed(buffer: bytes[..<split])
                if split < bytes.count { #expect(terminal.programStatusRecords.isEmpty) }
                terminal.feed(buffer: bytes[split...])
                #expect(terminal.programStatus()?.message == "Split 🚀")
                #expect(delegate.updates.count == 1)
            }
        }
        let terminal = Terminal(delegate: Delegate())
        terminal.feed(text: "\u{1b}]7501;state=working\u{1b}")
        #expect(terminal.programStatusRecords.isEmpty)
        terminal.feed(text: "X" + report("state=done"))
        #expect(terminal.programStatus()?.state == .done)
        for ending in ["\u{18}", "\u{1a}"] {
            terminal.feed(text: "\u{1b}]7501;state=clear" + ending)
            #expect(terminal.programStatus()?.state == .done)
        }
        for code in ["07501", "0007501", "7\u{0}501"] {
            terminal.feed(text: "\u{1b}]\(code);state=clear\u{7}")
            #expect(terminal.programStatus()?.state == .done)
        }
    }

    @Test func sequenceAtTheByteLimitIsAcceptedAndOneMoreByteIsRejected() {
        let terminal = Terminal(delegate: Delegate())
        let prefix = "state=working:future="
        let body = prefix + String(repeating: "x", count: 4087 - prefix.utf8.count)
        #expect(report(body).utf8.count == 4096)
        terminal.feed(text: report(body))
        #expect(terminal.programStatus()?.state == .working)
        let original = terminal.programStatusRecords
        terminal.feed(text: report(body + "x"))
        #expect(terminal.programStatusRecords == original)
    }

    @Test func everyByteAfterPendingStRecoversForTheNextReport() {
        for byte in UInt8.min...UInt8.max {
            let delegate = Delegate()
            let terminal = Terminal(delegate: delegate)
            terminal.feed(text: "\u{1b}]7501;state=working\u{1b}")
            terminal.feed(byteArray: [byte])
            #expect(delegate.updates.count == (byte == 0x5c ? 1 : 0))
            terminal.feed(text: report("state=done"))
            #expect(terminal.programStatus()?.state == .done)
            #expect(delegate.updates.count == (byte == 0x5c ? 2 : 1))
        }
    }

    @Test(arguments: [false, true])
    func nestedPendingStIsReplacedByNormalOuterState(outerHasPendingSt: Bool) {
        let terminal = Terminal(delegate: Delegate())
        terminal.registerOscHandler(code: 777) { [unowned terminal] _ in
            terminal.feed(text: "\u{1b}]7501;state=working:id=nested\u{1b}")
        }
        let suffix = outerHasPendingSt ? "\u{1b}]7501;state=done:id=outer\u{1b}" : ""
        terminal.feed(text: "\u{1b}]777;trigger\u{7}" + suffix)
        terminal.feed(text: "\\")
        #expect(terminal.programStatus(id: "nested") == nil)
        #expect(terminal.programStatus(id: "outer")?.state == (outerHasPendingSt ? .done : nil))
    }

    @Test(arguments: [false, true])
    func nestedParserResetPreservesItsPendingStOverRemainingOuterInput(outerHasPendingSt: Bool) {
        let terminal = Terminal(delegate: Delegate())
        terminal.registerOscHandler(code: 777) { [unowned terminal] _ in
            terminal.resetParserForTesting()
            terminal.feed(text: "\u{1b}]7501;state=working:id=nested\u{1b}")
        }
        let suffix = outerHasPendingSt ? "\u{1b}]7501;state=done:id=outer\u{1b}" : ""
        terminal.feed(text: "\u{1b}]777;trigger\u{7}" + suffix)
        terminal.feed(text: "\\")
        #expect(terminal.programStatus(id: "nested")?.state == .working)
        #expect(terminal.programStatus(id: "outer") == nil)
    }

    @Test func synchronousOverrideCanFeedAfterAnStSplit() {
        let terminal = Terminal(delegate: Delegate(), options: TerminalOptions(cols: 20, rows: 2))
        var calls = 0
        terminal.registerOscHandler(code: 7501) { _ in
            calls += 1
            terminal.feed(text: "nested")
        }
        terminal.feed(text: "\u{1b}]7501;state=working\u{1b}")
        terminal.feed(text: "\\tail")
        #expect(calls == 1)
        #expect(terminal.programStatusRecords.isEmpty)
        #expect(String(decoding: terminal.getBufferAsData(), as: UTF8.self).hasPrefix("nestedtail"))
    }

    @Test func screenChangesSoftResetPromptAndExitHaveTheRequiredLifetimes() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        for state in ["idle", "working", "blocked", "done", "error"] {
            terminal.feed(text: report("state=\(state):id=\(state)"))
        }
        let original = terminal.programStatusRecords
        terminal.feed(text: "\u{1b}[?1049h\u{1b}[!p\u{1b}[?1049l")
        #expect(terminal.programStatusRecords == original)
        terminal.feed(text: "\u{1b}]133;N\u{7}")
        #expect(terminal.programStatusRecords == original)
        terminal.feed(text: "\u{1b}[?1049h\u{1b}]133;A\u{7}")
        #expect(terminal.programStatusRecords == original)
        terminal.feed(text: "\u{1b}[?1049l\u{1b}]133;D\u{7}\u{1b}]133;A\u{7}")
        #expect(terminal.programStatusRecords.map(\.state) == [.idle, .done, .error])
        terminal.feed(text: report("state=working:id=new"))
        terminal.programStatusProcessExited()
        #expect(terminal.programStatusRecords.map(\.state) == [.idle, .done, .error])
        terminal.feed(text: "\u{1b}c")
        #expect(terminal.programStatusRecords.isEmpty)
        #expect(delegate.updates.last == [])
    }

    @Test func onlyAValidNewPromptClearsActiveRecords() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.feed(text: "\u{1b}]133;A\u{7}")
        let group = terminal.buffer.activeSemanticGroupID
        for state in ["idle", "working", "blocked", "done", "error"] {
            terminal.feed(text: report("state=\(state):id=build/\(state)"))
        }
        let original = terminal.programStatusRecords
        for marker in ["A;k=r", "A;k=invalid", "A;cl=invalid", "A;click_events=invalid",
                       "A;special_key=invalid", "A;k=c", "A;k=s", "A;k=i", "B", "A;k=i"] {
            terminal.feed(text: "\u{1b}]133;\(marker)\u{7}")
            #expect(terminal.programStatusRecords == original)
            #expect(terminal.buffer.activeSemanticGroupID == group)
        }
        terminal.feed(text: "\u{1b}]133;C\u{7}\u{1b}]133;D\u{7}")
        #expect(terminal.programStatusRecords == original)
        terminal.feed(text: "\u{1b}]133;A;k=invalid\u{7}")
        #expect(terminal.programStatusRecords == original)
        terminal.feed(text: "\u{1b}]133;A\u{7}")
        #expect(terminal.buffer.activeSemanticGroupID != group)
        #expect(terminal.programStatusRecords.map(\.state) == [.idle, .done, .error])
        #expect(delegate.updates.count == 6)
    }

    @Test func evictionUsesLastUpdateAndDoesNotRemoveDescendants() {
        let terminal = Terminal(delegate: Delegate())
        terminal.feed(text: report("state=working:id=old"))
        terminal.feed(text: report("state=done:id=old/child"))
        for i in 0..<254 { terminal.feed(text: report("state=idle:id=job\(i)")) }
        #expect(terminal.programStatusRecords.count == 256)
        _ = terminal.programStatus(id: "old") // A read does not refresh age.
        terminal.feed(text: report("state=idle:id=job0"))
        terminal.feed(text: report("state=idle:id=extra"))
        #expect(terminal.programStatus(id: "old") == nil)
        #expect(terminal.programStatus(id: "old/child") != nil)
        #expect(terminal.programStatus(id: "job0") != nil)
        #expect(terminal.programStatusRecords.count == 256)
    }

    @Test func oscNineDoesNotReplaceProgramStatus() {
        let terminal = Terminal(delegate: Delegate())
        terminal.feed(text: report("state=blocked:kind=auth:msg=\(base64("Sign in"))"))
        let original = terminal.programStatusRecords
        terminal.feed(text: "\u{1b}]9;4;1;75\u{7}")
        #expect(terminal.programStatusRecords == original)
    }

    @Test func terminfoReportsProgramStatusCapability() {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate)
        terminal.feed(text: "\u{1b}P+q507374\u{1b}\\")
        #expect(String(decoding: delegate.output, as: UTF8.self) == SwiftTermTerminfo.xtgettcapReplies["507374"])
        #expect(SwiftTermTerminfo.xtgettcapReplies["507374"]?.contains("37353031") == true)
    }
}
