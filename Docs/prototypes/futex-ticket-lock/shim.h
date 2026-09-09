#ifndef SWIFTTERM_SYNC_H
#define SWIFTTERM_SYNC_H
#include <stdint.h>
#include <stdbool.h>

bool swiftterm_sync_available(void);
int  swiftterm_sync_wait(uint32_t *addr, uint32_t value);
int  swiftterm_sync_wake_one(uint32_t *addr);
int  swiftterm_sync_wake_all(uint32_t *addr);

uint32_t swiftterm_atomic_fetch_add(uint32_t *addr, uint32_t delta);
uint32_t swiftterm_atomic_load_acquire(const uint32_t *addr);
void     swiftterm_atomic_store_release(uint32_t *addr, uint32_t value);
#endif
