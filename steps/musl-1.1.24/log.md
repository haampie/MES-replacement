# tcc-on-musl bootstrap log

Running notes on building tcc 0.9.26 against the new aarch64 musl libc
(see `build.sh` + `patches/`) and verifying self-hosting.

All work happens in the lima VM, under `~/bootstrap-tcc-musl/`.

## Setup

1. Extracted clean `tcc-0.9.26.tar.gz` into
   `~/bootstrap-tcc-musl/tcc-src/`.
2. Applied 6 arm64 simple-patches from
   `steps/tcc-0.9.26/simple-patches/`:
   - `arm64-asm-defs`, `arm64-asm-include` (add `#include "arm64-asm.c"`)
   - `arm64-va-builtin-loop` (tccgen.c; seed tcc miscompiles upstream form)
   - `arm64-load-const-lval`, `arm64-store-const-lval` (arm64-gen.c
     missing `VT_CONST|VT_LVAL` case)
   - `arm64-cvt-ftof-mask` (arm64-gen.c gen_cvt_ftof type-bits mask)
3. Copied in `MES-replacement/src/arm64-asm.c` (data-directive aarch64
   assembler).
4. Pre-built `lib/lib-arm64.c` -> `/tmp/lib-arm64.o` for the soft-float
   `__addtf3` / `__multf3` / ... helpers.  Also archived it as
   `$MUSL/lib/tcc/libtcc1.a` so the new tcc auto-finds it.
5. Built `tcc-musl` with the seed tcc, linking statically against the
   new musl + `crt1/crti/crtn` + `lib-arm64.o`.  Binary is 522 KB (no
   debug) / 1.2 MB (`-g`).

## Symptom

`tcc-musl` aborts on any invocation (including `--help`) with:

    tcc: error: memory full (malloc)

A standalone `malloc(1024)` test program built with the same toolchain
runs fine — so musl + soft-float runtime are individually OK.

## Bisection with gdb

Built tcc-musl-g with `-g`, broke on `tcc_malloc` and `tcc_error`:

| # | size  | caller                  | result   |
|---|-------|-------------------------|----------|
| 1 | 1560  | tcc_mallocz (tcc_new)   | ok       |
| 2 | 59    | tcc_strdup              | ok       |
| 3..14 | 48..139 | tcc_mallocz       | ok       |
| 15 | 786432 | tal_new (tccpp_new)    | **NULL** |

786432 = 768 KB = `TOKSYM_TAL_SIZE` in `tccpp.c:142`.  musl's malloc
returns NULL on the first sub-MB request even though earlier sub-2KB
requests succeeded against the same heap.

## Repro & narrowing

Standalone `malloc(786432)` works fine — but with a misleading caveat:
it grows the heap via `brk` through `__simple_malloc` (lite_malloc.c) +
`__expand_heap`, not the path tcc-musl is hitting.

In `tcc-musl` the heap is initialised differently and the 15th alloc
takes the *direct mmap* branch in the full `malloc.c` (line 291,
`if (n > MMAP_THRESHOLD) { ... __mmap(...) ... }` — MMAP_THRESHOLD =
`0x1c00 * 32` = 224 KB).

Per strace, the mmap **syscall** returns a valid pointer.  But musl's
`malloc` then returns NULL.  So the bug is in the C code that runs
between the successful mmap and the return — most likely the chunk
header setup:

    c = (void *)(base + SIZE_ALIGN - OVERHEAD);
    c->csize = len - (SIZE_ALIGN - OVERHEAD);
    c->psize = SIZE_ALIGN - OVERHEAD;
    return CHUNK_TO_MEM(c);

The seed tcc (live-bootstrap mes-libc-built tcc 0.9.26) is presumably
miscompiling one of these statements on aarch64 — a *new* codegen bug
distinct from the four already patched (load/store const-lval,
cvt-ftof-mask, va-builtin-loop).

## Status: parked

Pursuing self-hosting would require:
1. Bisecting `malloc.c` to find which statement gets miscompiled.
2. Writing another `arm64-gen.c` patch.

Not worth the time right now — the chroot bootstrap doesn't have GNU
make yet anyway, so this whole thing is future-work notes.  Reopen
when the chroot environment is closer to being able to actually run
`./configure && make` in-place.
