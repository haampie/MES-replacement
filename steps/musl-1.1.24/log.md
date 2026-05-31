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

A standalone test that runs the **exact same allocation sequence** (14
small allocs followed by `malloc(786432)`) compiled with the same seed
tcc against the same new musl works fine — so musl's `malloc.c` itself
is *not* miscompiled in any way that affects this case.  The earlier
"chunk-setup miscompile" hypothesis was wrong.

The bug is reached only via tcc-musl's own internal call chain.  In gdb
on tcc-musl, stepping into musl's `malloc` for the 786432-byte call
shows that `__mmap` returns -1 (MAP_FAILED) — but `strace` shows the
underlying `mmap` syscall returned a valid pointer (e.g.
`0xf9e695ca7000`).  So the bug is between `svc` returning and `__mmap`
returning.

## Real root cause: tcc miscompiles `-4096UL`

`mmap.c` calls `__syscall_ret(ret)` to translate kernel-style returns
to libc-style:

    long __syscall_ret(unsigned long r)
    {
        if (r > -4096UL) { errno = -r; return -1; }
        return r;
    }

Disassembly of `__syscall_ret` in tcc-musl shows:

      ldr x0, [x29, #160]       ; load r
      mov w1, #0xfffff000       ; load -4096UL  (BUG: 32-bit W register)
      cmp x0, x1                ; 64-bit compare

The `mov w1, #0xfffff000` writes only the low 32 bits and zero-extends,
giving x1 = `0x00000000fffff000`.  Any valid 64-bit pointer is greater
than that, so `__syscall_ret` thinks the syscall failed and returns -1.

Minimal repro (compiled with the seed tcc, linked against any libc):

    unsigned long a = -4096UL;            /* prints 0x00000000fffff000 (BUG) */
    unsigned long b = -4096ULL;           /* prints 0xfffffffffffff000 (ok)  */
    unsigned long c = 0xfffffffffffff000UL;  /* prints 0xfffffffffffff000 (ok) */

### Why

`tccpp.c:2429` (parse_number) sets the `must_64bit` flag for integer
suffixes:

    if (t == 'L') {
        ...
    #if !defined TCC_TARGET_X86_64 || defined TCC_TARGET_PE
        if (lcount == 2)
    #endif
            must_64bit = 1;

On aarch64 the `#if` is true, so `must_64bit` is only set for `LL`.
For single `L`, a constant whose value fits in 32 bits is typed
`TOK_CUINT` (32-bit unsigned).  `4096UL` -> 32-bit; unary minus on a
32-bit unsigned yields 32-bit `0xfffff000`; assignment to a 64-bit
`unsigned long` then zero-extends.

This affects every `-NUL` / `~NUL` constant whose magnitude fits in
32 bits, anywhere in any C source compiled by tcc for aarch64.  `musl`
has many such constants (mask values, sentinel returns) but they only
manifest when used in 64-bit context; `__syscall_ret` is the
load-bearing one for any mmap-returning code path.

### Fix

`steps/tcc-0.9.26/simple-patches/arm64-long-suffix-64bit` (TODO),
analogous to the existing arm64 parser/codegen patches: extend the
`#if` to also exempt `TCC_TARGET_ARM64`, so single `L` sets
`must_64bit = 1` on aarch64 too — matching ISO C where `sizeof(long)
== 8` on a 64-bit target.

    #if (!defined TCC_TARGET_X86_64 && !defined TCC_TARGET_ARM64) \
        || defined TCC_TARGET_PE

Verified: a tcc binary built with this patch in place generates
`mov x1, #0xfffffffffffff000` (the 64-bit `movn x1, #0xfff` encoding,
opcode 0x9281ffe1) for `-4096UL`, exactly the same as it already does
for `0xfffffffffffff000UL`.

## Status: needs full rebuild

Confirming end-to-end self-hosting requires rebuilding through the
whole chain with the fix in place:

1. Add the simple-patch to `steps/tcc-0.9.26/simple-patches/` and
   re-run that step to produce a fixed seed tcc.
2. Rebuild musl with the fixed seed tcc — this regenerates a correct
   `__syscall_ret` (and any other places affected by the constant
   bug).
3. Rebuild `tcc-musl` against the fixed musl.
4. Then attempt the actual self-hosting check (`tcc-musl` rebuilds
   `tcc.c` byte-identically).

Parked again at step 1 — wiring a new simple-patch into the existing
tcc-0.9.26 step is a small change but belongs in that step's branch,
not here.
