//
//  DescriptorFlags.swift
//  SwiftTerm
//
//  Descriptor flag helpers shared by the PTY launch path and the IO pipeline.
//
#if !SWIFTTERM_EMBEDDED
#if !os(WASI) && !os(Windows)
#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif

enum DescriptorFlags {
    /// Adds `FD_CLOEXEC` and keeps the other descriptor flags.
    /// - Returns: nil on success, or the errno of the failed `fcntl` call.
    static func setCloseOnExec(_ fd: Int32) -> Int32? {
        guard fd >= 0 else {
            return EBADF
        }
        let flags = fcntl(fd, F_GETFD, 0)
        guard flags >= 0 else {
            return errno
        }
        guard fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0 else {
            return errno
        }
        return nil
    }
}
#endif
#endif // !SWIFTTERM_EMBEDDED
