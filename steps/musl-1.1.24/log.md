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

## Resolution: kaem rebuild + full chain

Wired the new `arm64-long-suffix-64bit.{before,after}` simple-patch
into `steps/tcc-0.9.26/pass1.kaem` (alongside the existing arm64
patches), flipped `target_arm64/bootstrap.cfg`
`UPDATE_CHECKSUMS=True`, and re-ran `task5_arm64.sh`.  This rebuilds
the entire pre-tcc bootstrap chain (mes, tcc-boot0, tcc-boot1, ...) on
top of `tcc_cc`, which doesn't have the bug, so the rebuilt
`/usr/bin/tcc` is self-consistent with the patch.  Regenerated
checksums copied back into the step.

Then end-to-end:

1. **musl** rebuilt cleanly with the new `tcc` via `build.sh` — full
   `libc.a` + `crt*.o` install, no errors.  The regenerated
   `__syscall_ret` now contains the correct
   `mov x1, #0xfffffffffffff000` instead of the 32-bit truncated form.
2. **tcc-musl** rebuilt against the new musl, runs cleanly: `tcc-musl
   -version` works (no "memory full"), compiles a hello-world that
   links statically against the new musl and prints `hello musl`.
3. **Self-hosting fixed-point**: stage-2 (tcc-musl compiles tcc.c)
   produces a 522560-byte binary that compiles further sources.
   stage-3 (stage-2 compiles tcc.c) is **byte-identical** to stage-2.
   stage-1↔stage-2 differs by a handful of bytes around offset
   511246 — the expected libgcc/soft-float transition artifact
   between the mes-libc-linked seed and the musl-linked self-hosted
   tcc.  stage-2 == stage-3 is the correct fixed-point criterion.

Status: **DONE.**  Patched seed tcc -> musl -> tcc-musl self-hosts.

## Follow-up: array-form `va_list` exposes a second seed-tcc codegen bug

Patches 16-19 switch musl's aarch64 `va_list` to AAPCS64 array form
(`struct __va_list_struct va_list[1]`).  This is necessary for
in-musl printf-family forwarding but turns out to expose another
bug in seed tcc's `arm64-gen.c`: a *parameter* declared `va_list ap`
has its array decayed to a pointer at declaration time, so the
`gaddrof()` at the top of `gen_va_start`/`gen_va_arg` takes the
address of the parameter slot rather than the va_list itself.
Forwarded `va_arg` then reads garbage.

Fix lives in `steps/tcc-0.9.26/simple-patches/arm64-va-{start,arg}-param-decay.*`
and is wired into `pass1.kaem`.  See
`steps/binutils-2.30/log.md` "Issue 4" for full diagnosis + repro
(crash was `as-new` segfaulting in libiberty `vconcat_copy`).

Requires the same procedure as the long-suffix fix to roll out:
re-run `task5_arm64.sh` with `UPDATE_CHECKSUMS=True`, then rebuild
musl, `tcc-musl`, and binutils on top.

### Rollout progress (2026-05-31)

1. **Seed tcc rebuilt.** `task5_arm64.sh` with `UPDATE_CHECKSUMS=True`
   completed cleanly with both arm64 simple-patches active.  New
   `/usr/bin/tcc` is MD5 `4a3be79e11a653d7a1c9bc9c9f316b82`; updated
   checksums committed to `steps/tcc-0.9.26/tcc-0.9.26.arm64.checksums`.
2. **Fix verified at the seed level.**  Compiling
   `~/bootstrap-binutils/repro/vc2.c` with the new seed against the
   prior musl prints `inner: 100 200 300` (was garbage).  Confirms the
   va_list parameter-decay patch produces correct codegen.
3. **musl rebuilt.**  `build.sh` against the new seed produces a clean
   `libc.a` + crt*.o at `~/bootstrap-musl/opt/musl-new/`.  Built
   `libtcc1.a` (lib-arm64.o helpers) into `musl-new/lib/tcc/`.
4. **`tcc-musl` rebuilt** (2026-05-31, second attempt).  Following
   `pass1.kaem`'s tcc-boot0 invocation closely — in particular passing
   `-DCONFIG_TCC_LIBPATHS=...` and `-DTCC_LIBTCC1="libtcc1.a"` and
   including the prebuilt `libtcc1.a` (with `lib-arm64.o` soft-float
   helpers) in the link line — produces a working `tcc-musl`:

   ```
   tcc -g -static -nostdlib -nostdinc \
       -DBOOTSTRAP=1 -DHAVE_LONG_LONG=1 -DTCC_TARGET_ARM64=1 \
       -DCONFIG_TCCDIR=\"$OUT/tcc-prefix/lib/tcc\" \
       -DCONFIG_SYSROOT=\"/\" \
       -DCONFIG_TCC_CRTPREFIX=\"$MUSL/lib\" \
       -DCONFIG_TCC_ELFINTERP=\"/musl/loader\" \
       -DCONFIG_TCC_SYSINCLUDEPATHS=\"$MUSL/include\" \
       -DCONFIG_TCC_LIBPATHS=\"$MUSL/lib:$OUT/tcc-prefix/lib/tcc\" \
       -DTCC_LIBGCC=\"$MUSL/lib/libc.a\" -DTCC_LIBTCC1=\"libtcc1.a\" \
       -DCONFIG_TCCBOOT=1 -DCONFIG_TCC_STATIC=1 -DCONFIG_USE_LIBGCC=1 \
       -DTCC_VERSION=\"0.9.26\" -DONE_SOURCE=1 \
       -I . -I $MUSL/include -o tcc-musl \
       $MUSL/lib/crt1.o $MUSL/lib/crti.o tcc.c \
       $MUSL/lib/libc.a $MUSL/lib/tcc/libtcc1.a $MUSL/lib/crtn.o
   ```

   Source: pristine `tcc-0.9.26-1147-gee75a10c` + the 9 arm64
   simple-patches wired in `pass1.kaem` (`arm64-asm-defs`,
   `arm64-asm-include`, `arm64-va-builtin-loop`,
   `arm64-{load,store}-const-lval`, `arm64-cvt-ftof-mask`,
   `arm64-long-suffix-64bit`, `arm64-va-{start,arg}-param-decay`)
   plus `src/arm64-asm.c`.  An empty `config.h` is needed because
   `tcc.h:25` does `#include "config.h"`.

   Verified: `tcc-musl /tmp/hi.c -o /tmp/hi` produces a working
   static binary; the va_list forwarding repro (`vc.c` — inner sees
   `100 200 300`) passes, confirming the param-decay patches reached
   the output binary.

   The previous "blocked" segfault at 0x433c54 was almost certainly
   caused by a missing `CONFIG_TCC_LIBPATHS` / `TCC_LIBTCC1` plus no
   `libtcc1.a` in the link line — at link-time tcc-musl couldn't
   resolve the soft-float helpers (`__addtf3` etc.) and the binary
   ended up with unresolved symbols on the link path that
   manifested as a crash on real compile/link (while `-version` /
   `-E` / `-c` paths never touched them).

5. **Self-hosting fixed point reached** against new musl.  Same
   invocation as above, run twice:
   - stage1 = seed tcc (mes-libc-linked) compiles `tcc.c` → 1204604 bytes,
     sha256 `6fa0b171...`
   - stage2 = stage1 compiles `tcc.c` → 1204604 bytes, sha256 `133f3dc5...`
   - stage3 = stage2 compiles `tcc.c` → 1204604 bytes, sha256 `133f3dc5...`

   **stage2 == stage3 byte-identical.**  stage1 vs stage2 first
   differs at byte 511470 — the same libgcc/soft-float transition
   seam between the mes-libc-linked seed and the musl-linked
   self-hosted tcc that the original kaem-chain self-host saw
   (around offset 511246).  Fixed-point criterion (stage2 == stage3)
   is satisfied; `tcc-musl` self-hosts on musl correctly.

## Critical: tcc-musl is built WITHOUT `-DHAVE_FLOAT=1` → all FP constants are 0.0 (2026-06-01)

The `tcc-musl` build invocation above (step 4, the `tcc -g -static -nostdlib ...`
line) passes `-DBOOTSTRAP=1 -DHAVE_LONG_LONG=1 -DTCC_TARGET_ARM64=1` but **not**
`-DHAVE_FLOAT=1`.  In the bootstrappable 0.9.26 fork, *all* floating-point
handling is wrapped in `#if HAVE_FLOAT` (upstream tinycc has no such macro).  With
the macro undefined:

- `tccpp.c` parse_number: `#if HAVE_FLOAT tokc.d = strtod(token_buf, NULL); #endif`
  — the literal's value is never computed.
- `tccgen.c` init_putv: `#if HAVE_FLOAT *(double *)ptr = vtop->c.d; #endif` — the
  constant bytes are never written to the data section.

Net effect: **every `float`/`double` literal compiled by `tcc-musl` becomes
`0.0`** — even `1.0`/`2.0`.  Confirmed by compiling `double x = 38.53;` and
dumping `.data`: 8 zero bytes (correct is `a4 70 3d 0a d7 43 43 40`).  The
aarch64 codegen is fine (`ldr d0`, `fcvtzs`, `scvtf` all correct); only the
constant value is wrong.

### This is the single root cause of the entire GCC/musl cc1 crash taxonomy

`cc1` was compiled by `tcc-musl-stage3`, so every FP constant inside GCC's own
source is `0.0`.  Everything in `bootstrap-gcc/LOG.md` and
`bootstrap-musl-gcc/LOG.md` collapses to this one bug:

- `real.c:1724` `gcc_assert(digit <= 10)` ICE in `real_to_decimal_for_mode`
  (creduce-reduced to `a = 8 * 0.30102999566398119521; ... while(--a)`):
  real.c's internal `log10(2)` etc. are 0, so `a = 0`, `while(--a)` runs away.
- Bug 3 (`double f(void){return 1.0;}` crashes at -O1+): cc1 real-arithmetic on
  zeroed constants.
- Bug 4 / `pow(x, 2.0)` crash even at -O0: `fold_builtin_pow` compares the
  exponent against zeroed `REAL_VALUE` constants (2.0, 0.5).
- Bug 1 (CCP), Bug 2 (double→long double promotion), MPFR `dbl_int_bug`,
  GMP `2^63` configure probe — same zeroed-constant origin.

The many `-O0` / `-fno-tree-ccp` / stub workarounds in those logs become
unnecessary once tcc is fixed.

### Verified fix: add `-DHAVE_FLOAT=1` to the tcc-musl build

Built a stage-4 tcc inside the VM = `tcc-musl-stage3` compiling
`~/bootstrap-tcc-musl/tcc-src/tcc.c` (ONE_SOURCE, static) with **only**
`-DHAVE_FLOAT=1` added (plus `-DTCC_VERSION='"0.9.26"'` since config.h is empty,
and using the tcc-compatible `…/musl-new/include.tcc-bak` / `lib.tcc-bak`
headers — the plain `include` has a va_list form tcc rejects).  Results:

- `double x = 38.53;` → `.data` = `a4 70 3d 0a d7 43 43 40` (correct).
- double→long conversions: 38.53→38, 2.5→2, 7.0→7 (stage3 gave all 0).
- The original creduce reproduction (`real_to_decimal` + harness) prints
  `OK: 11` and exits 0 (stage3 timed out / ran away, exit 124).

**Action:** add `-DHAVE_FLOAT=1` to the `tcc-musl` build line in step 4 (and to
whatever drives the self-hosting stages) and rebuild stage1→stage3, so the
GCC-building compiler materializes FP constants.  No source patch needed — it is
a pure build-flag fix.  Note the mes-libc seed tcc (chroot `rootfs/usr/bin/tcc`)
builds float constants but mis-rounds some decimals (e.g. `38.53`→`43.3`) due to
mes-libc's `strtod`; that is a separate, seed-only issue — musl's `strtod` is
correct, so the musl-hosted stages are fine once `HAVE_FLOAT` is on.
