// Atomic integer operations for TempleCore (PureNative task handoff). Swift's own atomics
// (Synchronization.Atomic) need iOS 18; the app supports iOS 16, so these come from C11.
#ifndef CTEMPLEATOMICS_H
#define CTEMPLEATOMICS_H

#include <stdatomic.h>

typedef struct { _Atomic(long) value; } ct_atomic_long;

static inline void ct_store(ct_atomic_long *a, long v) { atomic_store_explicit(&a->value, v, memory_order_release); }
static inline long ct_load(ct_atomic_long *a) { return atomic_load_explicit(&a->value, memory_order_acquire); }
static inline long ct_exchange(ct_atomic_long *a, long v) { return atomic_exchange_explicit(&a->value, v, memory_order_acq_rel); }
static inline void ct_init(ct_atomic_long *a, long v) { atomic_init(&a->value, v); }
/** Sequentially consistent (handoff flags that must not miss each other). */
static inline void ct_store_sc(ct_atomic_long *a, long v) { atomic_store_explicit(&a->value, v, memory_order_seq_cst); }
static inline long ct_load_sc(ct_atomic_long *a) { return atomic_load_explicit(&a->value, memory_order_seq_cst); }
static inline long ct_add_sc(ct_atomic_long *a, long v) { return atomic_fetch_add_explicit(&a->value, v, memory_order_seq_cst); }
/** A CPU hint for spin-wait loops. */
static inline void ct_pause(void) {
#if defined(__aarch64__)
    __asm__ __volatile__("yield");
#elif defined(__x86_64__)
    __asm__ __volatile__("pause");
#endif
}

#endif
