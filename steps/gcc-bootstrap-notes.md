# GCC 4.7 aarch64 bootstrap — cross-cutting notes

These notes live with the MES-replacement chain because they are about how the
tcc-era tooling interacts with the GCC build. Per-step build logs are now under
`steps/` (see `steps/README.md`): `05-gcc-4.7-stage1` (C-only),
`06-musl-1.1.24-gcc` (pristine libc), `07-gcc-4.7-stage2` (C+C++). The original
raw logs are `bootstrap-gcc/LOG.md` and `bootstrap-musl-gcc/LOG.md`.

## Insight: the seed (mes-libc) tcc mis-compiles musl libc, but that does NOT block building GCC

After the `HAVE_FLOAT` fix (see `musl-1.1.24/log.md` and the
`project-tcc-fp-constant-bug` memory), the rebuilt chain runs:

```
seed tcc (mes-libc)  --builds-->  Stage-1 musl   (the "throwaway" libc)
Stage-1 musl + HAVE_FLOAT-fixed tcc-musl-stage3  --builds-->  GCC 4.7 (C only)
```

We discovered a clean separation of concerns:

- **The seed tcc mis-compiles musl's `vfprintf` float-formatting.** A hello-world
  built by the new GCC against Stage-1 musl prints `printf("%f", 38.53)` as
  `0.00`. This is the *libc* that is wrong, not the compiler: with the new GCC,
  FP constants, FP arithmetic, integer `printf`, and `va_arg(ap,double)` are all
  correct. The fault is in musl's `%f` code, which the seed tcc compiled
  incorrectly. (The mes-libc tcc has its own known FP quirks — e.g. `strtod`
  mis-rounding — so a complex FP routine like `vfprintf`'s dragon4/long-double
  path being subtly wrong is consistent.)

- **But that broken libc is good enough to build GCC.** GCC's build does not
  depend on `printf("%f")` being correct. The GCC binary it produces is a
  *correct* compiler (verified: it emits the exact IEEE-754 bytes for `38.53`,
  does `(long)d` and `d*2.0+f` correctly, passes doubles through varargs). So a
  libc that is wrong only in its FP *formatting* is a perfectly adequate
  scaffold for the compiler-compiler step.

This is the bootstrap analogue of "you don't need a correct `printf` to build a
correct compiler" — the defect is confined to a leaf function of the scaffold
libc and never reaches the artifact we care about.

## Open question (Stage 4): can this GCC rebuild musl correctly?

The natural next test, and the resolution of the above: rebuild musl with the
new GCC (`bootstrap-gcc/opt/bin/aarch64-unknown-linux-musl-gcc`) into
`bootstrap-musl-gcc/opt/musl`, then re-run the `printf("%f")` test against the
**gcc-built** musl. Expected: `%f` is now correct, because the new GCC compiles
musl's `vfprintf` correctly (unlike the seed tcc). If so, the scaffold musl can
be discarded and the chain is self-consistent.

**RESOLVED 2026-06-01 — YES.** Built **pristine musl 1.1.24 with ZERO source
patches** using the new GCC (`bootstrap-gcc/opt/bin/gcc`), only
`CFLAGS=-fno-tree-ccp`. The full libc — including every complex-math, floatscan,
decfloat, `rem_pio2_large`, `scalbnl`, `exp10`, and `drand48` file that the OLD
(FP-buggy-GCC) build needed 7 patches for — compiled cleanly. Installed to
`bootstrap-musl-gcc/opt/musl` (`libc.a` 2.7 MB, via binutils `ar`). A hello-world
linked against it prints `printf("%f", 38.53)` → **`38.530000`** (the seed-tcc
Stage-1 musl printed `0.00`). `%g`, `%e`, `%.2f`, `(long)d` all correct.

Conclusions:
- The `%f`→`0.00` defect was purely the seed (mes-libc) tcc miscompiling musl's
  `vfprintf`; the new GCC compiles it correctly. The scaffold (tcc-built) musl can
  now be discarded — the chain is self-consistent.
- **All 7 old `bootstrap-musl-gcc` musl patches were FP artifacts** of the
  HAVE_FLOAT bug; none are needed with the fixed GCC. The only musl build flag
  required is `-fno-tree-ccp` (same genuine CCP/TImode backend bug as the libgcc
  fix — not FP, not tcc).
- **Linking note (not a defect):** user programs must link the new GCC's
  `libgcc.a` (or `-lgcc`) for the aarch64 128-bit `long double` TFmode soft-float
  helpers (`__addtf3`/`__multf3`/`__netf2`/`__fixtfsi`/…) that `vfprintf`/`frexpl`
  reference. `-nostdlib` suppresses libgcc, so add
  `$(gcc -print-libgcc-file-name)` explicitly. This is normal aarch64 behaviour
  (hardware has no quad-float), not a musl or GCC bug.

## Necessary GCC patches / flags (current, post-stage1-rebuild 2026-06-02)

Only **one** source patch and one build flag remain, *provided* GCC is
configured against the pristine gcc-built musl with
`--with-native-system-header-dir=/include` (see below). Everything else in the
old GCC log was a `HAVE_FLOAT` artifact.

| # | What | Why | Status |
|---|------|-----|--------|
| 0001 | `libiberty/alloca.c` + `include/libiberty.h`: rename `C_alloca`→`alloca` | musl/tcc compat (same as Guix `fix-alloca`) | applied + committed |
| cfg | `--with-sysroot=bootstrap-musl-gcc/opt/musl --with-native-system-header-dir=/include` | use the **pristine** gcc-built musl whose `va_list` is `__builtin_va_list`; avoids the tcc-form `va_list[1]` conflict entirely (replaces patch 0002) | configure-time |
| flag | `make … CFLAGS_FOR_TARGET="-O2 -fno-tree-ccp"` | genuine GCC-4.7-aarch64 CCP/TImode backend segfault (`__cmpti2`/`__ucmpti2`); independent of tcc; also hits user code | build-time only |

Superseded (in `bootstrap-gcc/patches/superseded/`, with README):
- **0002** stdarg `__DEFINED_va_list` — sysroot artifact, see Stage 5 blocker #1;
  reverted 2026-06-02. The real fix is configuring against the pristine musl.
- **0004** sfp-exceptions stub — pure FP artifact, `sfp-exceptions.c` now builds at `-O2`.
- **0003** as written — its `-O0` half was an FP artifact, and it targeted the
  wrong make var (`HOST_LIBGCC2_CFLAGS`, which is host-only; the crash is in
  *target* libgcc → must use `CFLAGS_FOR_TARGET`).

Also dropped (were FP artifacts, now build clean): MPFR `mpfr_cv_dbl_int_bug=no`
override, GMP 2^63 configure-probe override. (`--disable-assembly` for GMP is
still required — that's a tcc-assembler limitation, unrelated to FP.)

## TODO carried forward (see also `steps/TODO.md` item 4)

**RESOLVED 2026-06-02 — patch 0002 DROPPED, stage-1 rebuilt against pristine
musl.** See "Stage 5 blocker #1" below. The fix was *not* fixincludes-related —
it was that the stage-1 gcc had baked in the **tcc-built scaffold** musl as its
sysroot, whose `bits/alltypes.h` declares `va_list` the tcc way. Rebuild stage-1
against the pristine gcc-built musl (`--with-native-system-header-dir=/include`)
and the patch vanishes, exactly like Guix's `gcc-muslboot`.

## Stage 5 (GCC C+C++) — blocker #1 RESOLVED 2026-06-02

Build dir now `bootstrap-gcc-2/build`, src Linaro 4.7.4. CC = a freshly rebuilt
stage-1 gcc, `--enable-languages=c,c++ --disable-build-with-cxx
--with-sysroot=<gcc-built musl> --with-native-system-header-dir=/include`.

1. **va_list conflict — ROOT CAUSE & FIX.** Error was
   `stdarg.h:102: conflicting types for 'va_list'`, musl's prior decl from
   `bits/alltypes.h:10`. It is a genuine *type* mismatch, not a guard-macro
   mismatch:
   - GCC's `__builtin_va_list` on aarch64 is `struct __va_list` (a bare struct).
   - The **tcc-built scaffold** musl (`bootstrap-musl/opt/musl-new`) declares
     `typedef __musl_va_list_t va_list[1];` — array-of-struct, the form patched
     in *for tcc* (tcc has no `__builtin_va_list`). struct ≠ array-of-struct →
     hard error.
   - The **pristine gcc-built** musl (`bootstrap-musl-gcc/opt/musl`, zero
     patches) declares `typedef __builtin_va_list va_list;` — identical to GCC's
     `__gnuc_va_list`, so re-typedef at stdarg.h:102 is legal (no error).

   The stage-1 gcc (`bootstrap-gcc/opt`) had `--with-sysroot=bootstrap-musl/opt/
   musl-new` (the tcc one) baked in, so when it compiled host objects
   (libiberty) it pulled the tcc-form `va_list`. `--with-sysroot` on the *stage-2*
   configure does NOT change which headers the host CC uses — only the stage-1
   compiler's own baked-in sysroot does. Patch 0002 (add `__DEFINED_va_list`
   guard) never helped, because `hashtab.c` includes `<stdio.h>` (→ tcc-form
   va_list) *before* `<stdarg.h>`.

   **FIX (done):** rebuilt stage-1 into a fresh prefix
   `bootstrap-gcc/opt-muslsysroot` (old `opt` kept) with
   `--with-sysroot=bootstrap-musl-gcc/opt/musl --with-native-system-header-dir=
   /include` (pristine musl puts headers in `/include`, not `/usr/include`), and
   **reverted patch 0002**. Verified: `#include <stdio.h>` then `<stdarg.h>` then
   a varargs fn compiles+runs (`42 38.530000`). Build tree
   `bootstrap-gcc/build-muslsysroot`, logs `configure.log`/`build.log`. Stage-2
   now uses `CC=bootstrap-gcc/opt-muslsysroot/bin/gcc`.

   Patch 0002 moved to `bootstrap-gcc/patches/superseded/` (FP/sysroot artifact,
   no longer applied). Remaining GCC source patch: only 0001 (alloca).

2. **`C++ preprocessor "/lib/cpp" fails sanity check`** at `configure-gcc` —
   **RESOLVED 2026-06-02.** Cause: I had passed `CXX=false`, so GCC 4.7's probe
   (it checks a C++ compiler even with `--disable-build-with-cxx`) fell back to
   the forbidden system `/lib/cpp`. FIX: GCC 4.7's `cc1plus` is written in **C**
   (the C++ self-host switch was 4.8), so the whole C++ front-end builds with the
   C-only stage-1 gcc. Point the probe at it as a C compiler:
   `CXX="…/opt-muslsysroot/bin/gcc -x c"`, `CXXCPP="…/gcc -x c -E"`. No C++
   stage0 needed; system `/lib/cpp` never touched.

## Stage 5 — DONE 2026-06-02 ✅

Full C+C++ GCC 4.7.4 built and installed to `bootstrap-gcc-2/opt`. `cc1plus`
(11 MB), `g++` driver, `libstdc++.a` (2.8 MB), `libsupc++.a` all present.
End-to-end C++11 test (`bootstrap-gcc-2/cxxtest.cpp`) compiles+runs:
`std::vector`+`std::sort`+lambda → `beta=1 gamma=2 alpha=3`; `throw`/`catch`
`std::runtime_error` → `exception: caught-ok` (libsupc++ unwinder OK); iostream
`38.53` (FP correct). Step recorded at
`steps/07-gcc-4.7-stage2/` (`log.md`, `patches/`, `sources`).

3. **libstdc++ vs musl** (3 new patches, all libc-agnostic, none FP):
   - `os_defines.h`: guard `__GLIBC_PREREQ` (undefined on musl → syntax error).
   - `os/gnu-linux/{ctype_base.h,ctype_inline.h,ctype_configure_char.cc}` →
     replaced with portable `os/generic/` versions (glibc `_ISupper`/
     `__ctype_b_loc` masks absent on musl; generic uses standard `isXXX()`).
   - `libiberty/strsignal.c`: const-qualify `psignal` arg to match musl.

   The old **sfp-exceptions stub** (0004) and **stdarg `__DEFINED_va_list`**
   (0002) were both reverted — verified unnecessary with the real (non-tcc)
   host gcc. Net stage-5 patch set: alloca (0001) + strsignal + the 3 libstdc++
   changes. See `steps/07-gcc-4.7-stage2/log.md`.
