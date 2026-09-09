import Foundation

enum SwiftTermTestSupport {
    static let queue = DispatchQueue(
        label: "Runner",
        qos: .userInteractive,
        attributes: .concurrent,
        autoreleaseFrequency: .inherit,
        target: nil
    )
}
