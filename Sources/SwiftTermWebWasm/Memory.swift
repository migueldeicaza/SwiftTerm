#if os(WASI)
import WASILibc
#elseif canImport(Darwin)
import Darwin
#else
import Glibc
#endif

#if arch(wasm32)
@_silgen_name("llvm.wasm.memory.size.i32")
private func wasmMemorySize(_ memory: Int32) -> Int32
#endif

/// Only allocations from this API can be read or written through ABI pointers.
/// This also prevents a host from replacing Swift heap metadata with a copy call.
final class HostMemory {
    private struct Allocation {
        let pointer: UnsafeMutableRawPointer
        let count: UInt32
    }
    private var allocations: [UInt32: Allocation] = [:]
    private var allocatedBytes = 0
    func allocate(_ count: UInt32) -> UInt32 {
        guard count > 0, count <= UInt32(ABI.maximumSnapshot),
              Int(count) <= ABI.maximumSnapshot - allocatedBytes,
              let pointer = malloc(Int(count)) else { return 0 }
        let address = UInt(bitPattern: pointer)
        guard address <= UInt32.max else { free(pointer); return 0 }
        let result = UInt32(address)
        allocations[result] = Allocation(pointer: pointer, count: count)
        allocatedBytes += Int(count)
        return result
    }
    func release(_ address: UInt32) -> Int32 {
        if address == 0 { return ABI.ok }
        guard let allocation = allocations.removeValue(forKey: address) else { return ABI.invalidArgument }
        allocatedBytes -= Int(allocation.count)
        free(allocation.pointer)
        return ABI.ok
    }
    static func inBounds(_ address: UInt32, _ length: UInt32, memoryBytes: UInt64) -> Bool {
        if length == 0 { return UInt64(address) <= memoryBytes }
        return address != 0 && UInt64(address) + UInt64(length) <= memoryBytes
    }
    func valid(_ address: UInt32, _ length: UInt32) -> Bool {
        #if arch(wasm32)
        let size = UInt64(UInt32(bitPattern: wasmMemorySize(0))) * 65536
        #else
        let size = UInt64(UInt32.max) + 1
        #endif
        guard Self.inBounds(address, length, memoryBytes: size) else { return false }
        if length == 0 { return true }
        for (base, allocation) in allocations {
            if address >= base && UInt64(address) + UInt64(length) <= UInt64(base) + UInt64(allocation.count) {
                return true
            }
        }
        return false
    }
    func read(_ address: UInt32, _ length: UInt32) -> [UInt8]? {
        guard valid(address, length) else { return nil }
        if length == 0 { return [] }
        guard let pointer = UnsafePointer<UInt8>(bitPattern: UInt(address)) else { return nil }
        return Array(UnsafeBufferPointer(start: pointer, count: Int(length)))
    }
    func copy(_ bytes: ArraySlice<UInt8>, to address: UInt32, capacity: UInt32) -> Int32 {
        guard valid(address, capacity) else { return ABI.outOfBounds }
        guard UInt64(bytes.count) <= UInt64(capacity) else { return ABI.bufferTooSmall }
        if bytes.isEmpty { return 0 }
        guard let pointer = UnsafeMutablePointer<UInt8>(bitPattern: UInt(address)) else { return ABI.outOfBounds }
        bytes.withUnsafeBufferPointer { source in
            pointer.update(from: source.baseAddress!, count: source.count)
        }
        return Int32(bytes.count)
    }
}

func monotonicMilliseconds() -> UInt64 {
    #if os(WASI)
    var nanoseconds: UInt64 = 0
    guard __wasi_clock_time_get(1, 1_000_000, &nanoseconds) == 0 else { return 0 }
    return nanoseconds / 1_000_000
    #else
    var time = timespec()
    guard clock_gettime(CLOCK_MONOTONIC, &time) == 0, time.tv_sec >= 0, time.tv_nsec >= 0 else { return 0 }
    return UInt64(time.tv_sec) * 1000 + UInt64(time.tv_nsec) / 1_000_000
    #endif
}
