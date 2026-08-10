import Testing
import SwiftTerm

struct SwiftTermBuildInfoTests {
    @Test func versionContainsTheBestAvailableIdentifier() {
        let expectedBase = SwiftTermBuildInfo.tag
            ?? SwiftTermBuildInfo.commit.map { String($0.prefix(12)) }
            ?? "unknown"

        #expect(SwiftTermBuildInfo.version.hasPrefix(expectedBase))
        #expect(
            SwiftTermBuildInfo.version.hasSuffix("-modified")
                == (SwiftTermBuildInfo.hasUncommittedChanges == true)
        )
    }

    @Test func commitIsAFullGitObjectIdentifierWhenAvailable() {
        if let commit = SwiftTermBuildInfo.commit {
            #expect(commit.count == 40 || commit.count == 64)
            #expect(commit.allSatisfy { $0.isHexDigit })
        }
    }
}
