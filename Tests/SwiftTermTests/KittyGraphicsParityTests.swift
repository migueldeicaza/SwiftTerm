import Foundation
import Testing

@testable import SwiftTerm

@Suite(.serialized)
struct KittyGraphicsParityTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func send(
        _ terminal: Terminal,
        control: String,
        payload: [UInt8] = []
    ) {
        let encoded = Data(payload).base64EncodedString()
        terminal.feed(text: "\u{1b}_G\(control);\(encoded)\u{1b}\\")
    }

    private func response(_ delegate: TerminalTestDelegate) -> [UInt8]? {
        delegate.sentData.last
    }

    @Test func exactResponsesAndQuietCoercion() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        send(terminal, control: "a=t,f=24,s=1,v=1,i=7,p=3", payload: [1, 2, 3])
        #expect(response(delegate) == Array("\u{1b}_Gi=7,p=3;OK\u{1b}\\".utf8))

        delegate.clearSentData()
        send(terminal, control: "a=t,f=24,s=1,v=1,i=8,q=1", payload: [1])
        #expect(response(delegate) == Array("\u{1b}_Gi=8;ENODATA: insufficient data\u{1b}\\".utf8) ||
                response(delegate) == Array("\u{1b}_Gi=8;EINVAL: bad payload\u{1b}\\".utf8))

        delegate.clearSentData()
        send(terminal, control: "a=t,f=24,s=1,v=1,i=9,q=3", payload: [1])
        #expect(delegate.sentData.isEmpty)
    }

    @Test func identifiersAreExclusiveBeforeMutation() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        send(terminal, control: "a=t,f=24,s=1,v=1,i=7,I=8,p=9", payload: [1, 2, 3])
        #expect(response(delegate) == Array(
            "\u{1b}_Gi=7,I=8,p=9;EINVAL: image ID and number are mutually exclusive\u{1b}\\".utf8))
        #expect(terminal.kittyGraphicsRenderSnapshot().imagesById.isEmpty)
    }

    @Test func zeroLimitDisablesProtocolAndResponses() {
        let configuration = KittyGraphicsConfiguration(storageLimitBytesPerScreen: 0)
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(kittyGraphics: configuration)
        send(terminal, control: "a=q,f=24,s=1,v=1,i=1", payload: [1, 2, 3])
        #expect(delegate.sentData.isEmpty)
        #expect(terminal.kittyGraphicsRenderSnapshot().imagesById.isEmpty)
    }

    @Test func strictBase64AndZeroFormat() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        terminal.feed(text: "\u{1b}_Ga=t,f=24,s=1,v=1,i=1;AQ I=\u{1b}\\")
        #expect(terminal.kittyGraphicsRenderSnapshot().imagesById[1] == nil)

        delegate.clearSentData()
        send(terminal, control: "a=t,f=0,s=1,v=1,i=2", payload: [10, 20, 30, 40])
        #expect(Array(terminal.kittyGraphicsRenderSnapshot().imagesById[2]?.rgba ?? Data()) == [10, 20, 30, 40])
    }

    @Test func imageNumberAndImplicitIdsDoNotReplaceClientImages() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        send(terminal, control: "a=t,f=24,s=1,v=1,i=1", payload: [1, 2, 3])
        delegate.clearSentData()
        send(terminal, control: "a=t,f=24,s=1,v=1,I=42", payload: [4, 5, 6])
        #expect(response(delegate) == Array("\u{1b}_Gi=2,I=42;OK\u{1b}\\".utf8))

        delegate.clearSentData()
        send(terminal, control: "a=t,f=24,s=1,v=1", payload: [7, 8, 9])
        let snapshot = terminal.kittyGraphicsRenderSnapshot()
        #expect(snapshot.imagesById[1] != nil)
        #expect(snapshot.imagesById[2] != nil)
        #expect(snapshot.imagesById.keys.contains { $0 >= 0x8000_0000 })
        #expect(delegate.sentData.isEmpty)
    }

    @Test func primaryAndAlternateStoresAreIndependent() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 3)
        send(terminal, control: "a=t,f=24,s=1,v=1,i=1", payload: [1, 2, 3])
        #expect(terminal.kittyGraphicsRenderSnapshot().imagesById[1] != nil)

        terminal.feed(text: "\u{1b}[?1049h")
        #expect(terminal.kittyGraphicsRenderSnapshot().imagesById.isEmpty)
        send(terminal, control: "a=t,f=24,s=1,v=1,i=2", payload: [4, 5, 6])
        #expect(terminal.kittyGraphicsRenderSnapshot().imagesById[2] != nil)

        terminal.feed(text: "\u{1b}[?47l")
        let primary = terminal.kittyGraphicsRenderSnapshot()
        #expect(primary.imagesById[1] != nil)
        #expect(primary.imagesById[2] == nil)
    }

    @Test func snapshotContainsAnonymousPlacementsInRenderOrder() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 10, rows: 5)
        send(terminal, control: "a=T,f=24,s=1,v=1,i=1,c=2,r=2,z=3,C=1", payload: [1, 2, 3])
        send(terminal, control: "a=p,i=1,c=1,r=1,z=-2,C=1")
        let snapshot = terminal.kittyGraphicsRenderSnapshot()
        #expect(snapshot.placements.count == 2)
        #expect(snapshot.placements[0].zIndex == -2)
        #expect(snapshot.placements[1].zIndex == 3)
        #expect(Set(snapshot.placements.map(\.token)).count == 2)
        #expect(snapshot.placements.allSatisfy { $0.placementId == 0 })
    }

    @Test func anonymousAndClientPlacementsUseDistinctKeys() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 8, rows: 6)
        send(terminal, control: "a=T,f=24,s=1,v=1,i=1,p=1,C=1", payload: [1, 2, 3])
        terminal.feed(text: "\u{1b}[3;1H")
        send(terminal, control: "a=p,i=1,C=1")

        let before = terminal.kittyGraphicsRenderSnapshot()
        #expect(before.placements.count == 2)
        let anonymousToken = try #require(
            before.placements.first(where: { $0.placementId == 0 })?.token)
        #expect(before.placements.contains(where: { $0.placementId == 1 }))

        terminal.feed(text: "\u{1b}[5;1H")
        send(terminal, control: "a=p,i=1,p=1,C=1")
        let after = terminal.kittyGraphicsRenderSnapshot()
        #expect(after.placements.count == 2)
        #expect(after.placements.first(where: { $0.placementId == 0 })?.token == anonymousToken)
        #expect(after.placements.contains(where: { $0.placementId == 1 }))
    }

    @Test func csiScrollCommandsMovePlacementsAndBumpGeneration() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 8, rows: 6)
        terminal.feed(text: "\u{1b}[2;5r\u{1b}[4;1H")
        send(terminal, control: "a=T,f=24,s=1,v=1,i=1,p=1,C=1", payload: [1, 2, 3])
        let initial = terminal.kittyGraphicsRenderSnapshot()
        #expect(try #require(initial.placements.first).geometry.row == 3)

        terminal.feed(text: "\u{1b}[2S")
        let scrolledUp = terminal.kittyGraphicsRenderSnapshot()
        #expect(try #require(scrolledUp.placements.first).geometry.row == 1)
        #expect(scrolledUp.storageGeneration > initial.storageGeneration)

        terminal.feed(text: "\u{1b}[1T")
        let scrolledDown = terminal.kittyGraphicsRenderSnapshot()
        #expect(try #require(scrolledDown.placements.first).geometry.row == 2)
        #expect(scrolledDown.storageGeneration > scrolledUp.storageGeneration)
    }

    @Test func survivingScrollbackTrimBumpsPlacementGeneration() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 8, rows: 6)
        terminal.feed(text: "\u{1b}[3;1H")
        send(terminal, control: "a=T,f=24,s=1,v=1,i=1,p=1,C=1", payload: [1, 2, 3])
        let before = terminal.kittyGraphicsRenderSnapshot()

        terminal.trimKittyPlacementRows()
        let after = terminal.kittyGraphicsRenderSnapshot()
        #expect(try #require(after.placements.first).geometry.row == 1)
        #expect(after.storageGeneration > before.storageGeneration)
    }

    @Test func retransmissionRemovesPlacementsAndChangesGeneration() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        send(terminal, control: "a=T,f=24,s=1,v=1,i=1,c=1,r=1,C=1", payload: [1, 2, 3])
        let before = terminal.kittyGraphicsRenderSnapshot()
        send(terminal, control: "a=t,f=24,s=1,v=1,i=1", payload: [4, 5, 6])
        let after = terminal.kittyGraphicsRenderSnapshot()
        #expect(after.placements.isEmpty)
        #expect(after.storageGeneration > before.storageGeneration)
        #expect(after.imagesById[1]!.contentGeneration > before.imagesById[1]!.contentGeneration)
    }

    @Test func animationFramesUseDeterministicTime() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        send(terminal, control: "a=T,f=32,s=1,v=1,i=1,c=1,r=1,C=1", payload: [10, 20, 30, 255])
        delegate.clearSentData()
        send(terminal, control: "a=f,f=32,s=1,v=1,i=1,z=10,X=1", payload: [40, 50, 60, 255])
        #expect(response(delegate) == Array("\u{1b}_Gi=1,r=2;OK\u{1b}\\".utf8))

        delegate.clearSentData()
        send(terminal, control: "a=a,i=1,s=3,c=1,v=1")
        #expect(delegate.sentData.isEmpty)
        _ = terminal.kittyGraphicsAdvanceAnimations(monotonicNanoseconds: 1_000_000)
        _ = terminal.kittyGraphicsAdvanceAnimations(monotonicNanoseconds: 41_000_000)
        #expect(Array(terminal.kittyGraphicsRenderSnapshot().imagesById[1]!.rgba) == [40, 50, 60, 255])
    }

    @Test func animationOverwriteComposeAndFrameDelete() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        send(terminal, control: "a=t,f=32,s=2,v=1,i=1", payload: [1, 2, 3, 255, 4, 5, 6, 255])
        send(terminal, control: "a=f,f=32,s=1,v=1,i=1,x=1,X=1", payload: [9, 8, 7, 255])
        send(terminal, control: "a=a,i=1,c=2")
        #expect(Array(terminal.kittyGraphicsRenderSnapshot().imagesById[1]!.rgba) ==
                [0, 0, 0, 0, 9, 8, 7, 255])

        terminal.feed(text: "\u{1b}_Ga=d,d=f,i=1,r=2\u{1b}\\")
        #expect(Array(terminal.kittyGraphicsRenderSnapshot().imagesById[1]!.rgba) ==
                [1, 2, 3, 255, 4, 5, 6, 255])
    }

    @Test func editingFrameOneReplacesRootWithoutExtraStorage() throws {
        let configuration = KittyGraphicsConfiguration(storageLimitBytesPerScreen: 8)
        let (terminal, _) = TerminalTestHarness.makeTerminal(kittyGraphics: configuration)
        send(terminal, control: "a=t,f=32,s=1,v=1,i=1", payload: [1, 2, 3, 255])
        send(terminal, control: "a=f,f=32,s=1,v=1,i=1,X=1", payload: [4, 5, 6, 255])
        #expect(terminal.kittyGraphicsState.totalImageBytes == 8)

        send(terminal, control: "a=f,f=32,s=1,v=1,i=1,r=1,X=1", payload: [7, 8, 9, 255])
        #expect(terminal.kittyGraphicsState.totalImageBytes == 8)
        terminal.feed(text: "\u{1b}_Ga=d,d=f,i=1,r=2\u{1b}\\")

        let root = try #require(terminal.kittyGraphicsRenderSnapshot().imagesById[1])
        #expect(Array(root.rgba) == [7, 8, 9, 255])
        #expect(terminal.kittyGraphicsState.totalImageBytes == 4)
    }

    @Test func screenSwitchRestartsActiveAnimationSchedule() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        send(terminal, control: "a=T,f=32,s=1,v=1,i=1,p=1,C=1", payload: [1, 2, 3, 255])
        send(terminal, control: "a=f,f=32,s=1,v=1,i=1,z=60000,X=1", payload: [4, 5, 6, 255])
        send(terminal, control: "a=a,i=1,r=1,z=60000,s=3,c=1")
        let beforeSwitch = terminal.kittyAnimationTimerSerial

        terminal.feed(text: "\u{1b}[?1049h")
        let onAlternate = terminal.kittyAnimationTimerSerial
        terminal.feed(text: "\u{1b}[?1049l")
        let onPrimary = terminal.kittyAnimationTimerSerial
        #expect(onAlternate > beforeSwitch)
        #expect(onPrimary > onAlternate)

        _ = terminal.kittyGraphicsAdvanceAnimations(monotonicNanoseconds: 1)
        _ = terminal.kittyGraphicsAdvanceAnimations(monotonicNanoseconds: 60_000_000_001)
        let image = try #require(terminal.kittyGraphicsRenderSnapshot().imagesById[1])
        #expect(Array(image.rgba) == [4, 5, 6, 255])
    }

    @Test func compositionWorksOnRootFrameAndResponds() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        send(terminal, control: "a=t,f=32,s=2,v=1,i=1",
             payload: [255, 0, 0, 255, 0, 255, 0, 255])
        delegate.clearSentData()
        send(terminal, control: "a=c,i=1,c=1,r=1,x=1,y=0,w=1,h=1,X=0,Y=0,C=1")
        #expect(response(delegate) == Array("\u{1b}_Gi=1;OK\u{1b}\\".utf8))
        #expect(Array(terminal.kittyGraphicsRenderSnapshot().imagesById[1]!.rgba) ==
                [255, 0, 0, 255, 255, 0, 0, 255])
    }

    @Test func finalChunkCanIncreaseQuietLevel() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        send(terminal, control: "a=t,f=24,s=1,v=2,i=1,m=1", payload: [1, 2, 3])
        #expect(delegate.sentData.isEmpty)
        send(terminal, control: "m=0,q=2", payload: [4, 5, 6])
        #expect(delegate.sentData.isEmpty)
        #expect(terminal.kittyGraphicsRenderSnapshot().imagesById[1] != nil)
    }

    @Test func firstRetransmissionChunkInvalidatesOldImage() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        send(terminal, control: "a=T,f=24,s=1,v=1,i=1,p=1,C=1", payload: [1, 2, 3])
        send(terminal, control: "a=t,f=24,s=1,v=2,i=1,m=1", payload: [4, 5, 6])
        let snapshot = terminal.kittyGraphicsRenderSnapshot()
        #expect(snapshot.imagesById[1] == nil)
        #expect(snapshot.placements.isEmpty)
    }

    @Test func failedRetransmissionDoesNotRestoreOldPixels() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        send(terminal, control: "a=T,f=24,s=1,v=1,i=1,p=1,C=1", payload: [1, 2, 3])
        delegate.clearSentData()
        send(terminal, control: "a=t,f=24,s=1,v=1,i=1", payload: [4])
        #expect(response(delegate) == Array("\u{1b}_Gi=1;ENODATA: insufficient data\u{1b}\\".utf8))
        let snapshot = terminal.kittyGraphicsRenderSnapshot()
        #expect(snapshot.imagesById[1] == nil)
        #expect(snapshot.placements.isEmpty)
    }

    @Test func parentWithoutPlacementIdUsesPreferredPlacement() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal(cols: 8, rows: 6)
        send(terminal, control: "a=T,f=24,s=1,v=1,i=1,p=5,C=1", payload: [1, 2, 3])
        terminal.feed(text: "\u{1b}[3;1H")
        send(terminal, control: "a=p,i=1,p=2,C=1")
        delegate.clearSentData()
        send(terminal, control: "a=p,i=1,p=7,P=1,V=1,C=1")
        let child = terminal.kittyGraphicsRenderSnapshot().placements.first { $0.placementId == 7 }
        #expect(child?.geometry.row == 3)
        #expect(response(delegate) == Array("\u{1b}_Gi=1,p=7;OK\u{1b}\\".utf8))
    }

    @Test func relativePlacementCycleIsRejectedBeforeReplacement() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        send(terminal, control: "a=T,f=24,s=1,v=1,i=1,p=1,C=1", payload: [1, 2, 3])
        send(terminal, control: "a=p,i=1,p=2,P=1,Q=1,C=1")
        delegate.clearSentData()
        send(terminal, control: "a=p,i=1,p=1,P=1,Q=2,C=1")
        #expect(response(delegate) == Array(
            "\u{1b}_Gi=1,p=1;ECYCLE: parent chain creates a cycle\u{1b}\\".utf8))
        #expect(terminal.kittyGraphicsRenderSnapshot().placements.count == 2)
    }

    @Test func uppercaseDeleteOnlyReclaimsSelectedUnusedImages() {
        let (terminal, delegate) = TerminalTestHarness.makeTerminal()
        send(terminal, control: "a=T,f=24,s=1,v=1,i=1,p=1,C=1", payload: [1, 2, 3])
        send(terminal, control: "a=t,f=24,s=1,v=1,i=2", payload: [4, 5, 6])
        delegate.clearSentData()
        terminal.feed(text: "\u{1b}_Ga=d,d=I,i=1,p=99\u{1b}\\")
        #expect(delegate.sentData.isEmpty)
        let snapshot = terminal.kittyGraphicsRenderSnapshot()
        #expect(snapshot.imagesById[1] != nil)
        #expect(snapshot.imagesById[2] != nil)
    }

    @Test func rangeDeleteDoesNotNormalizeInvertedBounds() {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        send(terminal, control: "a=T,f=24,s=1,v=1,i=2,p=1,C=1", payload: [1, 2, 3])
        terminal.feed(text: "\u{1b}_Ga=d,d=R,x=5,y=1\u{1b}\\")
        #expect(terminal.kittyGraphicsRenderSnapshot().imagesById[2] != nil)
    }

    @Test func ghosttyRawAndZlibFixturesDecodeToCanonicalRgba() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        send(terminal, control: "a=t,f=24,s=20,v=15,i=1",
             payload: Array(try fixture("image-rgb-none-20x15-2147483647-raw.data")))
        send(terminal, control: "a=t,f=24,s=128,v=96,o=z,i=2",
             payload: Array(try fixture("image-rgb-zlib_deflate-128x96-2147483647-raw.data")))
        let snapshot = terminal.kittyGraphicsRenderSnapshot()
        let raw = try #require(snapshot.imagesById[1])
        let zlib = try #require(snapshot.imagesById[2])
        #expect(raw.rgba.count == 20 * 15 * 4)
        #expect(Array(raw.rgba.prefix(4)) == [0x0d, 0x1a, 0x1e, 0xff])
        #expect(Array(raw.rgba.suffix(4)) == [0xa0, 0xaf, 0x70, 0xff])
        #expect(zlib.rgba.count == 128 * 96 * 4)
        #expect(Array(zlib.rgba.prefix(4)) == [0x0b, 0x18, 0x1f, 0xff])
        #expect(Array(zlib.rgba.suffix(4)) == [0xa9, 0xb9, 0x85, 0xff])
    }

    @Test func ghosttyPngFixturesDecodeAtIngress() throws {
        let (terminal, _) = TerminalTestHarness.makeTerminal()
        send(terminal, control: "a=t,f=100,i=1",
             payload: Array(try fixture("image-png-none-50x76-2147483647-raw.data")))
        send(terminal, control: "a=t,f=100,i=2", payload: Array(try fixture("dog.png")))
        let snapshot = terminal.kittyGraphicsRenderSnapshot()
        let palette = try #require(snapshot.imagesById[1])
        let dog = try #require(snapshot.imagesById[2])
        #expect(palette.width == 50)
        #expect(palette.height == 76)
        #expect(palette.rgba.count == 50 * 76 * 4)
        #expect(dog.width == 500)
        #expect(dog.height == 306)
        #expect(dog.rgba.count == 500 * 306 * 4)
        #expect(Array(dog.rgba.prefix(4)) == [178, 174, 150, 255])
        #expect(Array(dog.rgba.suffix(4)) == [221, 177, 141, 255])
    }

    @Test func storageLimitRejectsOversizeAndEvictsTransientFirst() {
        let tiny = KittyGraphicsConfiguration(storageLimitBytesPerScreen: 3)
        let (rejected, rejectedDelegate) = TerminalTestHarness.makeTerminal(kittyGraphics: tiny)
        send(rejected, control: "a=t,f=32,s=1,v=1,i=1", payload: [1, 2, 3, 4])
        #expect(response(rejectedDelegate) == Array("\u{1b}_Gi=1;ENOMEM: out of memory\u{1b}\\".utf8))
        #expect(rejected.kittyGraphicsRenderSnapshot().imagesById.isEmpty)

        let bounded = KittyGraphicsConfiguration(storageLimitBytesPerScreen: 8)
        let (terminal, _) = TerminalTestHarness.makeTerminal(kittyGraphics: bounded)
        send(terminal, control: "a=T,f=32,s=1,v=1,i=1,p=1,C=1", payload: [1, 2, 3, 4])
        send(terminal, control: "a=t,f=32,s=1,v=1,i=2,N=1", payload: [5, 6, 7, 8])
        send(terminal, control: "a=t,f=32,s=1,v=1,i=3", payload: [9, 10, 11, 12])
        let snapshot = terminal.kittyGraphicsRenderSnapshot()
        #expect(snapshot.imagesById[1] != nil)
        #expect(snapshot.imagesById[2] == nil)
        #expect(snapshot.imagesById[3] != nil)
    }
}
