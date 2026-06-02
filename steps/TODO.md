# Build reproducibility TODO

Cross-cutting improvements to make the aarch64 bootstrap chain fully
script-driven and byte-reproducible. Each item is something currently done by
hand or under-documented.

## 1. Wire `libtcc1.a` (aarch64 soft-float helpers) into the musl build

**What it is:** `bootstrap-tcc-musl/tcc-src/lib/lib-arm64.c` compiles to the
TFmode soft-float helpers (`__addtf3`, `__multf3`, `__subtf3`, `__divtf3`,
float/int conversions, comparisons) that 128-bit `long double` needs — aarch64
has no hardware quad-float. tcc emits calls to these and links them from
`$MUSL/lib/tcc/libtcc1.a`. **Required**, not optional.

**Problem:** `steps/musl-1.1.24/build.sh` does NOT build it. It was a manual
setup step recorded only in prose in `steps/musl-1.1.24/log.md` ("Setup" step 4).
The exact `tcc` compile flags were never pinned, so a fresh rebuild
(`tcc -c -DTCC_TARGET_ARM64=1 lib-arm64.c` + `tcc -ar rc libtcc1.a lib-arm64.o`)
produces a functionally-identical archive that differs from the saved
`lib.tcc-bak/tcc/libtcc1.a` by ~72 bytes of object-name/flag metadata.

**TODO:** add a step (in `build.sh` or a dedicated `steps/` script) that builds
`libtcc1.a` from `lib/lib-arm64.c` with pinned flags, installs it to
`$PREFIX/lib/tcc/libtcc1.a`, and records the expected size/sha256 so it is
verifiable. Decide the canonical flag set (with or without `-g`,
`-DHAVE_FLOAT=1`, `-DHAVE_LONG_LONG=1`).

## 2. `-DHAVE_FLOAT=1` is mandatory for every tcc-musl self-host stage  (FIXED 2026-06-01)

The bootstrappable 0.9.26 fork wraps ALL floating-point handling in
`#if HAVE_FLOAT` (parse in `tccpp.c`, data-section store in `tccgen.c
init_putv`). Without the macro, every float/double literal compiles to `0.0` —
which silently miscompiled GCC's `cc1` (see `steps/musl-1.1.24/log.md`). The
tcc-musl build line MUST pass `-DHAVE_FLOAT=1` (and keep `-DHAVE_LONG_LONG=1`).
Now applied in `bootstrap-tcc-musl/build-havefloat.sh`.

**TODO:** fold this into the canonical/committed tcc-musl build recipe (not just
the ad-hoc script) and add a post-build assertion: compile `double x=38.53;` and
check `.data` == `a4 70 3d 0a d7 43 43 40` so a regression is caught immediately.

## 4. Eliminate GCC patch 0002 (va_list) via Guix-style sysroot config

Patch `0002` (define `__DEFINED_va_list` in `gcc/ginclude/stdarg.h`) is a
workaround for a "conflicting types for `va_list`" error: GCC's `fixincludes`
generates "fixed" copies of musl headers, and GCC's own `stdarg.h` guards with
`_VA_LIST_DEFINED` while musl guards with `__DEFINED_va_list`, so both definitions
land in one TU.

Guix's `commencement.scm` (`gcc-muslboot0` / `gcc-muslboot`) needs **no** such
patch. Instead of `--with-sysroot=<musl>` (which causes fixincludes to mangle the
musl headers), it uses:
- `--with-build-sysroot=<musl>/include` (build-time header root),
- `--with-native-system-header-dir=/include`,
- env `C_INCLUDE_PATH=<musl>/include`, `LIBRARY_PATH=<musl>/lib:<tcc>/lib`.

This header-search arrangement avoids the duplicate-`va_list` collision entirely.
**TODO:** switch the GCC stage configs to the Guix `--with-build-sysroot` +
`--with-native-system-header-dir` + `C_INCLUDE_PATH` scheme and drop patch 0002,
confirming the build still links libgcc cleanly. (Note: Guix's only source edits
are `fix-alloca` = our 0001, and a `struct ucontext`→`ucontext_t` unwind fix that
does not apply to aarch64.)

## 3. Capture the GCC/prereq build environment in a script

The GMP/MPFR/MPC/GCC builds currently rely on an ad-hoc environment
(`PATH=bootstrap-binutils/opt/bin:bootstrap-tcc-musl`, `CC=tcc-musl-stage3`,
`AR/AS/LD/RANLIB` from binutils, `CFLAGS=-DHAVE_ALLOCA_H`) reconstructed from
`config.log`. **TODO:** commit a driver script per package so the recipe isn't
only recoverable by archaeology.
