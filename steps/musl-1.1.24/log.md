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

## Verification attempt outside the kaem chain

Tried to short-circuit the bootstrap by rebuilding the seed tcc
binary in-tree:

1. Applied the patch directly to `tccpp.c` in the source tree under
   `~/bootstrap-tcc-musl/tcc-src/`.
2. Used the existing seed tcc (`rootfs/usr/bin/tcc`, built by
   `tcc_cc` in the M2-based bootstrap chain) to compile this patched
   `tcc.c` into a new binary `tcc-fixed`, linked against mes-libc.
3. Confirmed at the parser level: `tcc-fixed` compiled
   `unsigned long a = -4096UL` into the correct
   `mov x1, #0xfffffffffffff000` (`movn x1, #0xfff`, opcode
   `0x9281ffe1`).  Repro program now prints
   `0xfffffffffffff000` for `-4096UL`.
4. Ran `build.sh` with `TCC=tcc-fixed` to rebuild musl from scratch.
   Got partway through (~1500 .o files) before crashing on
   `src/math/pow_data.c:20`: tcc-fixed rejects
   `0x1.555555555556p-2 * -2` as "initializer element is not
   constant" and segfaults — even though the *seed* tcc accepts the
   exact same line.

`tcc-fixed` is the seed tcc's source plus a one-line `tccpp.c` patch.
The patch only affects integer-L suffix parsing — yet the resulting
binary handles float constant folding differently from the seed.  The
explanation is the bootstrap layer mismatch: `tcc.c` itself uses
`L`-suffixed constants in its own internal logic.  The buggy seed
parses those constants as 32-bit (so the seed's *own* internals are
self-consistent with the bug).  When the seed compiles patched
`tcc.c`, the same internal constants are still parsed as 32-bit (seed
runs its buggy parser) but produce a binary whose runtime parser
*also* treats user constants as 64-bit — exposing a latent mismatch in
the resulting tcc's own folding logic.

Stage-2 (using `tcc-fixed` to rebuild `tcc-fixed`) also fails on
`pow_data.c` and produces a byte-different binary from stage-1, so
fixed-point hasn't been reached either.

## Status: needs full kaem rebuild of the seed tcc

The clean way out is to re-run the existing
`steps/tcc-0.9.26/pass1.kaem` flow with the new patch wired in, so
`tcc_cc` (which doesn't suffer the bug) parses the patched `tcc.c`.
That produces a self-consistent fixed seed tcc, after which `build.sh`
should rebuild musl correctly and `tcc-musl` should self-host.

Concrete next steps:

1. Add a `simple-patch` invocation to `pass1.kaem` for the new
   `arm64-long-suffix-64bit.{before,after}` files in
   `steps/tcc-0.9.26/simple-patches/` (already saved on this branch),
   alongside the existing arm64 patches.
2. Re-run the tcc-0.9.26 step in the chroot so `/usr/bin/tcc` is
   replaced.
3. Rerun `build.sh` here with the new TCC.
4. Rebuild `tcc-musl` against the rebuilt musl.
5. Check self-hosting: compile tcc.c with tcc-musl, compare against
   the binary built from the same source by the rebuilt seed tcc.

Parked here — wiring the patch into pass1.kaem and re-running the
kaem chain belongs in the `tcc-0.9.26` step's branch, not in this
musl-notes branch.
