//
//  File.swift
//  
//
//  Created by Miguel de Icaza on 3/4/20.
//

import Foundation
#if !os(iOS) && !os(tvOS) && !os(Windows)

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

        var master: Int32 = 0
        
        let pid = forkpty(&master, nil, nil, &desiredWindowSize)
        if pid < 0 {
            return nil
        }
        if pid == 0 {
            if let cCurrentDirectory {
                _ = chdir(cCurrentDirectory)
            }
            
            _ = execve(cExecutable, cArgs.base, cEnv.base)
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
