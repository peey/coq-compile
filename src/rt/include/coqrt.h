#ifndef COQRT_H
#define COQRT_H

#include <assert.h>
#include <unistd.h>
#include <stdint.h>
#include <stdbool.h>

#define universal_t uintptr_t

typedef struct baselimit {
  universal_t *base;
  universal_t *limit;
} bumpptr_t;

typedef struct ret {
  bumpptr_t bumpptrs;
  universal_t val;
} coqret_t;

typedef struct alloc {
  bumpptr_t bumpptrs;
  universal_t *ptr;
} alloc_t;


extern bool debug;

extern coqret_t coq_main(bumpptr_t bumpptrs);
void coq_done(bumpptr_t bumpptrs, universal_t o);
void coq_error(void);
alloc_t coq_alloc(bumpptr_t bumpptrs, universal_t words) __attribute((always_inline));
bumpptr_t coq_gc(void);
void coq_report(universal_t value);

#endif /* COQRT_H */
