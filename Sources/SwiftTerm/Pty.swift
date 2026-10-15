//
//  File.swift
//  
//
//  Created by Miguel de Icaza on 3/4/20.
//

#if !SWIFTTERM_EMBEDDED
import Foundation
#if !os(WASI) && !os(iOS) && !os(tvOS) && !os(Windows) && !os(Android)

/**
 * APIs to assist in controlling a Unix pseudo-terminal from Swift.
 *
 *This provides a wrapper for
 * the libc `forkpty`API in the form of `fork(andExec:args:env:desiredWindowSize:` method,
 * `setWinSize` and `availableBytes`
 */
public class PseudoTerminalHelpers {
    private struct CStringArray {
        let base: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        let count: Int
    }

#if os(macOS)
    /// Turns the forked child's exec into one that keeps only its terminal.
    ///
    /// `fork` duplicates every descriptor the host holds, and `execve` keeps
    /// all of them that are not close-on-exec. The host cannot mark them all:
    /// Darwin has no `pipe2(O_CLOEXEC)` or `SOCK_CLOEXEC`, so a descriptor
    /// another thread is creating is inheritable until its owner flags it, and
    /// much host code never does. A shell that inherited a pipe's writer holds
    /// it for as long as it lives, so that pipe's reader never sees EOF, and
    /// every program the user runs in the terminal inherits the host's
    /// sockets and files too.
    ///
    /// `POSIX_SPAWN_SETEXEC` makes `posix_spawn` replace the calling process
    /// as `execve` would, and `POSIX_SPAWN_CLOEXEC_DEFAULT` closes every
    /// descriptor its file actions do not name. The actions name only 0, 1
    /// and 2, which `forkpty` has already made the PTY; the controlling
    /// terminal and session are properties of the process, not of a
    /// descriptor, and survive the exec unchanged.
    ///
    /// Built in the parent: the child of a multithreaded process may run only
    /// async-signal-safe code, so it must not allocate.
    private struct TerminalExecBoundary {
        let attributes: UnsafeMutablePointer<posix_spawnattr_t?>
        let fileActions: UnsafeMutablePointer<posix_spawn_file_actions_t?>

        /// nil, with `errno` set, when the attributes cannot be built.
        static func make() -> TerminalExecBoundary? {
            let attributes = UnsafeMutablePointer<posix_spawnattr_t?>.allocate(capacity: 1)
            let fileActions = UnsafeMutablePointer<posix_spawn_file_actions_t?>.allocate(capacity: 1)
            let attributesResult = posix_spawnattr_init(attributes)
            guard attributesResult == 0 else {
                attributes.deallocate()
                fileActions.deallocate()
                errno = attributesResult
                return nil
            }
            let actionsResult = posix_spawn_file_actions_init(fileActions)
            guard actionsResult == 0 else {
                posix_spawnattr_destroy(attributes)
                attributes.deallocate()
                fileActions.deallocate()
                errno = actionsResult
                return nil
            }
            let boundary = TerminalExecBoundary(attributes: attributes, fileActions: fileActions)
            var result = posix_spawnattr_setflags(
                attributes,
                Int16(POSIX_SPAWN_SETEXEC | POSIX_SPAWN_CLOEXEC_DEFAULT)
            )
            for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] where result == 0 {
                result = posix_spawn_file_actions_addinherit_np(fileActions, descriptor)
            }
            guard result == 0 else {
                boundary.destroy()
                errno = result
                return nil
            }
            return boundary
        }

        func destroy() {
            posix_spawn_file_actions_destroy(fileActions)
            posix_spawnattr_destroy(attributes)
            fileActions.deallocate()
            attributes.deallocate()
        }
    }
#endif

    private static func allocateCStringArray(_ strings: [String]) -> CStringArray? {
        let base = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        var initializedCount = 0

        for (index, string) in strings.enumerated() {
            guard let duplicated = strdup(string) else {
                for cleanupIndex in 0..<initializedCount {
                    free(base[cleanupIndex])
                }
                base.deallocate()
                return nil
            }
            base[index] = duplicated
            initializedCount += 1
        }

        base[strings.count] = nil
        return CStringArray(base: base, count: strings.count)
    }

    private static func freeCStringArray(_ array: CStringArray) {
        for index in 0..<array.count {
            free(array.base[index])
        }
        array.base.deallocate()
    }

    /**
     * This method both forks and executes the provided command under a Pseudo Terminal (pty)
     * - Parameter andExec: the name of the executable to run
     * - Parameter args: arguments to be passed to the executable
     * - Parameter env: the environment variables for the child process
     * - Parameter desiredWindowSize: the window size that will be set on the pseudo terminal.
     *
     * - Returns: nil on error, or a tuple containing the process ID, and the file descriptor to the primary side of the newly created pseudo-terminal.
     */
    public static func fork (andExec: String, args: [String], env: [String], currentDirectory: String? = nil, desiredWindowSize: inout winsize) -> (pid: pid_t, masterFd: Int32)?
    {
        guard let cArgs = allocateCStringArray(args) else {
            return nil
        }
        guard let cEnv = allocateCStringArray(env) else {
            freeCStringArray(cArgs)
            return nil
        }
        guard let cExecutable = strdup(andExec) else {
            freeCStringArray(cEnv)
            freeCStringArray(cArgs)
            return nil
        }

        var cCurrentDirectory: UnsafeMutablePointer<CChar>?
        if let currentDirectory {
            guard let duplicatedCurrentDirectory = strdup(currentDirectory) else {
                free(cExecutable)
                freeCStringArray(cEnv)
                freeCStringArray(cArgs)
                return nil
            }
            cCurrentDirectory = duplicatedCurrentDirectory
        }

        defer {
            freeCStringArray(cArgs)
            freeCStringArray(cEnv)
            free(cExecutable)
            if let cCurrentDirectory {
                free(cCurrentDirectory)
            }
        }

        // Build the signal state before fork. The child must use only
        // async-signal-safe system calls until execve.
        var defaultAction = sigaction()
#if canImport(Darwin)
        defaultAction.__sigaction_u.__sa_handler = SIG_DFL
#elseif canImport(Musl)
        defaultAction.__sa_handler.sa_handler = SIG_DFL
#else
        defaultAction.__sigaction_handler.sa_handler = SIG_DFL
#endif
        sigemptyset(&defaultAction.sa_mask)
        defaultAction.sa_flags = 0
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
#if os(macOS)
        guard let execBoundary = TerminalExecBoundary.make() else {
            return nil
        }
        defer { execBoundary.destroy() }
        // Plain pointers, so the child reads no Swift aggregate after fork.
        let spawnAttributes = execBoundary.attributes
        let spawnFileActions = execBoundary.fileActions
#endif
        var master: Int32 = 0

        let pid = forkpty(&master, nil, nil, &desiredWindowSize)
        if pid < 0 {
            return nil
        }
        if pid == 0 {
            // Signal ignores and the calling thread's mask survive exec.
            // A server can ignore SIGINT for a DispatchSource or block it on
            // a worker thread. Do not pass that policy to terminal programs.
            // Reset dispositions before unblocking, so no inherited handler
            // can run in the child between fork and exec. Some platforms
            // reserve signal numbers; sigaction rejects those with EINVAL.
            var number: Int32 = 1
            while number < NSIG {
                if number != SIGKILL && number != SIGSTOP {
                    _ = sigaction(number, &defaultAction, nil)
                }
                number += 1
            }
            if sigprocmask(SIG_SETMASK, &emptyMask, nil) != 0 {
                _exit(127)
            }
            if let cCurrentDirectory {
                _ = chdir(cCurrentDirectory)
            }
            
#if os(macOS)
            // Exec keeping only the terminal (see `TerminalExecBoundary`).
            // Returns only on failure.
            _ = posix_spawn(nil, cExecutable, spawnFileActions, spawnAttributes, cArgs.base, cEnv.base)
#else
            _ = execve(cExecutable, cArgs.base, cEnv.base)
#endif
            _exit(127)
        }
        return (pid, master)
    }
    
    /**
     * Sets the window size of the underlying pseudo terminal.
     * - Parameter masterPtyDescriptor: a pseudo-terminal master file descriptor, as returned by fork(andExec:)
     * - Returns: the value from calling the ioctl
     */
    public static func setWinSize (masterPtyDescriptor: Int32, windowSize: inout winsize) -> Int32
    {
#if os(macOS)
        return ioctl(masterPtyDescriptor, TIOCSWINSZ, &windowSize)
#else
	return ioctl(masterPtyDescriptor, UInt(TIOCSWINSZ), &windowSize)
#endif
    }
    
    /**
     * Returns the number of available bytes to be read from the file descriptor
     */
    public static func availableBytes (fd: Int32) -> (status: Int32, size: Int32)
    {
        var size: Int32 = 0
        let status = ioctl (fd, 0x4004667f /* FIONREAD */, &size)
        return (status, size)
    }

    /// Reads the enabled `termios.c_cc` bytes from a PTY.
    ///
    /// The result contains only C0 and DEL values. A disabled entry, NUL, and
    /// values outside that range are not returned. The caller must use the
    /// approximation when this method returns `nil`.
    public static func terminalControlBytesForPaste(
        masterPtyDescriptor: Int32
    ) -> Set<UInt8>? {
        guard masterPtyDescriptor >= 0 else { return nil }

        var attributes = termios()
        guard tcgetattr(masterPtyDescriptor, &attributes) == 0 else { return nil }

        var indices: [Int32] = [
            VEOF, VEOL, VERASE, VINTR, VKILL, VQUIT, VSTART, VSTOP, VSUSP,
        ]
#if os(macOS)
        indices += [VDISCARD, VDSUSP, VEOL2, VLNEXT, VREPRINT, VSTATUS, VWERASE]
#elseif os(Linux)
        indices += [VDISCARD, VEOL2, VLNEXT, VREPRINT, VSWTC, VWERASE]
#endif

        let disabledValue = fpathconf(masterPtyDescriptor, Int32(_PC_VDISABLE))
        let disabledByte: UInt8? = disabledValue >= 0 && disabledValue <= 0xff
            ? UInt8(disabledValue)
            : nil
        let controlCharacters = withUnsafeBytes(of: &attributes.c_cc) { Array($0) }

        var result: Set<UInt8> = []
        for indexValue in indices {
            let index = Int(indexValue)
            guard controlCharacters.indices.contains(index) else { continue }
            let byte = controlCharacters[index]
            guard byte != 0 else { continue }
            if let disabledByte, byte == disabledByte { continue }
            guard byte < 0x20 || byte == 0x7f else { continue }
            result.insert(byte)
        }
        return result
    }
}
#endif

#endif // !SWIFTTERM_EMBEDDED
