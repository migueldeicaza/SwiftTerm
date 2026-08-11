#include "shim.h"
#include <stdatomic.h>
#include <errno.h>
#include <os/os_sync_wait_on_address.h>

bool swiftterm_sync_available(void) {
    if (__builtin_available(macOS 14.4, iOS 17.4, *)) {
        return &os_sync_wait_on_address != NULL;   // weak import null check
    }
    return false;
}

int swiftterm_sync_wait(uint32_t *addr, uint32_t value) {
    if (__builtin_available(macOS 14.4, iOS 17.4, *)) {
        return os_sync_wait_on_address(addr, (uint64_t)value, 4,
                                       OS_SYNC_WAIT_ON_ADDRESS_NONE);
    }
    errno = ENOTSUP;
    return -1;
}

int swiftterm_sync_wake_one(uint32_t *addr) {
    if (__builtin_available(macOS 14.4, iOS 17.4, *)) {
        return os_sync_wake_by_address_any(addr, 4, OS_SYNC_WAKE_BY_ADDRESS_NONE);
    }
    errno = ENOTSUP;
    return -1;
}

int swiftterm_sync_wake_all(uint32_t *addr) {
    if (__builtin_available(macOS 14.4, iOS 17.4, *)) {
        return os_sync_wake_by_address_all(addr, 4, OS_SYNC_WAKE_BY_ADDRESS_NONE);
    }
    errno = ENOTSUP;
    return -1;
}

uint32_t swiftterm_atomic_fetch_add(uint32_t *addr, uint32_t delta) {
    return atomic_fetch_add_explicit((_Atomic uint32_t *)addr, delta, memory_order_relaxed);
}
uint32_t swiftterm_atomic_load_acquire(const uint32_t *addr) {
    return atomic_load_explicit((const _Atomic uint32_t *)addr, memory_order_acquire);
}
void swiftterm_atomic_store_release(uint32_t *addr, uint32_t value) {
    atomic_store_explicit((_Atomic uint32_t *)addr, value, memory_order_release);
}
