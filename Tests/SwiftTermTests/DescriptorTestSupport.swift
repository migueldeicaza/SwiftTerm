//
//  DescriptorTestSupport.swift
//  SwiftTermTests
//
//  Shared helpers for tests that check which open file a descriptor number
//  refers to, and that reserve a closed number to detect a wrong close.
//
#if !os(iOS) && !os(Windows)
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

/// Identifies the open file behind a descriptor number.
struct DescriptorIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let rdev: dev_t
    let mode: mode_t
}

enum DescriptorTestError: Error {
    case missingDescriptor(Int32, Int32)
    case couldNotDuplicateDescriptor(Int32, Int32)
    case couldNotReserveDescriptor(Int32)
}

func descriptorIdentity(_ descriptor: Int32) throws -> DescriptorIdentity {
    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
        throw DescriptorTestError.missingDescriptor(descriptor, errno)
    }
    return DescriptorIdentity(
        device: info.st_dev,
        inode: info.st_ino,
        rdev: info.st_rdev,
        mode: info.st_mode)
}

func descriptorRefersToSameOpenFile(
    _ descriptor: Int32,
    as identity: DescriptorIdentity
) -> Bool {
    guard let current = try? descriptorIdentity(descriptor) else {
        return false
    }
    return current == identity
}

/// Reserves exactly `target` from an owned, unrelated descriptor. Only a
/// duplicate returned by F_DUPFD_CLOEXEC is closed while retrying; the source
/// descriptor and any other number are never touched. Suites that run in
/// parallel can hold `target` for a while, so this retries for about a second.
func reserveDescriptor(at target: Int32, from source: Int32) throws -> Int32 {
    for _ in 0..<1000 {
        let duplicate = fcntl(source, F_DUPFD_CLOEXEC, target)
        if duplicate < 0 {
            throw DescriptorTestError.couldNotDuplicateDescriptor(source, errno)
        }
        if duplicate == target {
            return duplicate
        }
        close(duplicate)
        Thread.sleep(forTimeInterval: 0.001)
    }
    throw DescriptorTestError.couldNotReserveDescriptor(target)
}

/// Signals once from a worker thread; waits with a timeout.
final class ThreadCompletion: @unchecked Sendable {
    private let condition = NSCondition()
    private var done = false

    func signal() {
        condition.lock()
        done = true
        condition.broadcast()
        condition.unlock()
    }

    func wait(timeout: TimeInterval) -> Bool {
        let limit = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !done {
            if !condition.wait(until: limit) {
                return done
            }
        }
        return true
    }
}
#endif
