// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Allocator shim for libraries that get dlopen()ed with RTLD_DEEPBIND.
//
// The FlexLM client linked into Cadence Genus dlopen()s libudev with
// RTLD_DEEPBIND, so libudev binds malloc/realloc/free straight to glibc. Genus
// however exports its own allocator from the executable, and glibc-internal
// allocations made on libudev's behalf (strdup, getcwd, ...) go through that
// global allocator. libudev then realloc()s/free()s those pointers with glibc
// and aborts with "realloc(): invalid pointer" during license checkout.
//
// Linking this shim as the first DT_NEEDED of libudev puts these definitions
// first in libudev's deep-bind scope; they forward to whatever allocator the
// main program uses (Genus's own, or glibc's for everything else).

#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stddef.h>

void *malloc(size_t n);
void *calloc(size_t n, size_t s);
void *realloc(void *p, size_t n);
void free(void *p);
size_t malloc_usable_size(void *p);

static void *(*g_malloc)(size_t);
static void *(*g_calloc)(size_t, size_t);
static void *(*g_realloc)(void *, size_t);
static void (*g_free)(void *);
static size_t (*g_usable)(void *);

// Resolve a symbol in the main program's global scope. RTLD_DEFAULT is no good
// here: from inside a deep-bound object it finds this shim again. If the main
// program yields nothing (or us), fall back to the next definition (glibc).
static void *lookup(const char *name, void *self) {
  void *main_prog = dlopen(NULL, RTLD_NOW | RTLD_NOLOAD);
  void *sym = main_prog ? dlsym(main_prog, name) : NULL;
  if (!sym || sym == self) {
    sym = dlsym(RTLD_NEXT, name);
  }
  return sym;
}

__attribute__((constructor)) static void init(void) {
  if (g_malloc) {
    return;
  }
  g_calloc = lookup("calloc", (void *)calloc);
  g_realloc = lookup("realloc", (void *)realloc);
  g_free = lookup("free", (void *)free);
  g_usable = lookup("malloc_usable_size", (void *)malloc_usable_size);
  g_malloc = lookup("malloc", (void *)malloc);
}

void *malloc(size_t n) {
  init();
  return g_malloc(n);
}

void *calloc(size_t n, size_t s) {
  init();
  return g_calloc(n, s);
}

void *realloc(void *p, size_t n) {
  init();
  return g_realloc(p, n);
}

void free(void *p) {
  init();
  g_free(p);
}

size_t malloc_usable_size(void *p) {
  init();
  return g_usable(p);
}

// glibc's reallocarray calls its internal realloc, bypassing any interposed
// allocator, so route it through realloc explicitly.
void *reallocarray(void *p, size_t n, size_t s) {
  size_t total;
  if (__builtin_mul_overflow(n, s, &total)) {
    errno = ENOMEM;
    return NULL;
  }
  return realloc(p, total);
}
