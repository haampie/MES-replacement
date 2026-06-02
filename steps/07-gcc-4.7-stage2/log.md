# 07 — GCC 4.7 (Linaro 4.7.4) aarch64, stage 2 (C **and** C++)

Final compiler of the ab-initio chain: a self-contained GCC 4.7.4 that builds
both C and C++ for `aarch64-unknown-linux-musl`, with a working libstdc++.

- **Source:** `gcc-linaro-4.7-2013.11.tar.bz2` (see `sources`). 4.7's `cc1plus`
  is written in C (the C++ self-host switch landed in 4.8), so the C++ front-end
  builds with a C-only host compiler — no C++ stage0 is needed.
- **Host compiler (CC):** `bootstrap-gcc/opt-muslsysroot/bin/gcc` — the stage-1
  GCC rebuilt against the **pristine** gcc-built musl. Its baked-in sysroot is
  what makes the host see `va_list = __builtin_va_list` (see patch notes below).
- **binutils:** `bootstrap-binutils/opt/bin/{ar,as,ranlib,nm}`.
- **GMP/MPFR/MPC:** prebuilt in `bootstrap-gcc/prereqs` (GMP `--disable-assembly`
  — a tcc-assembler limitation, unrelated to FP).
- **Build dir:** `bootstrap-gcc-2/build`; **prefix:** `bootstrap-gcc-2/opt`.
- **Sources tracked in git:** worktree `bootstrap-gcc-2/src/gcc-linaro-4.7-2013.11`
  (branch off the `bootstrap-gcc/src` repo). The `.patch` files in `patches/`
  are `git format-patch 4cb83a339..HEAD` (base = pristine tarball commit).

## Configure

```
CC=bootstrap-gcc/opt-muslsysroot/bin/gcc
CXX="…/gcc -x c"   CXXCPP="…/gcc -x c -E"   # 4.7 probes a C++ compiler even
                                            # with --disable-build-with-cxx;
                                            # point it at our C gcc, never /lib/cpp
AR/AS/RANLIB/NM = bootstrap-binutils/opt/bin/*
CFLAGS="-O2 -fno-tree-ccp -DHAVE_ALLOCA_H"
--build/--host/--target=aarch64-unknown-linux-musl
--with-sysroot=bootstrap-musl-gcc/opt/musl --with-native-system-header-dir=/include
--with-gmp/--with-mpfr/--with-mpc=bootstrap-gcc/prereqs
--enable-languages=c,c++ --enable-static --disable-shared
--enable-threads=single --disable-threads --disable-libstdcxx-pch
--disable-build-with-cxx --disable-bootstrap --disable-multilib
--disable-decimal-float --disable-lto --disable-lto-plugin --disable-plugin
--disable-{libatomic,libcilkrts,libgomp,libitm,libmudflap,libquadmath,libsanitizer,libssp,libvtv}
```

## Build / install

```
make -j4 CFLAGS_FOR_TARGET="-O2 -fno-tree-ccp" CXXFLAGS_FOR_TARGET="-O2 -fno-tree-ccp"
make install
```

`-fno-tree-ccp` (both host CFLAGS and target FLAGS) works around a genuine
GCC-4.7-aarch64 CCP/TImode backend segfault (`__cmpti2`/`__ucmpti2`); it is not
a tcc or FP artifact and also hits user code.

## Patches (4, net minimal set)

The tree differs from the pristine tarball in exactly four places:

1. **`libiberty/alloca.c` + `include/libiberty.h`** — rename `C_alloca`→`alloca`
   (same as Guix `fix-alloca`; musl/tcc compat).
2. **`libiberty/strsignal.c`** — const-qualify the `psignal` message arg to match
   musl's prototype.
3. **`libstdc++-v3/.../os/gnu-linux/os_defines.h`** — guard `__GLIBC_PREREQ`
   (undefined on musl; otherwise `#if __GLIBC_PREREQ(2,15)` is a syntax error:
   "missing binary operator before token (").
4. **`libstdc++-v3/.../os/gnu-linux/{ctype_base.h,ctype_inline.h,ctype_configure_char.cc}`**
   — replaced with the portable `config/os/generic/` versions. The gnu-linux
   ctype uses glibc-internal mask names (`_ISupper`, …) and `__ctype_b_loc()`,
   which musl does not expose. The generic config defines its own mask bits and
   classifies via the standard `isXXX()` functions. (Same approach as Alpine /
   musl-cross-make.)

Two earlier workarounds were tried and then verified **unnecessary** with the
real (non-tcc) host gcc, so they are NOT in the patch set:

- **stdarg `__DEFINED_va_list` guard** — a sysroot artifact, not a real fix. The
  host CC now compiles against the pristine musl whose `va_list` is
  `__builtin_va_list`, identical to GCC's `__gnuc_va_list`, so the re-typedef at
  `stdarg.h:102` is legal.
- **`libgcc/config/aarch64/sfp-exceptions.c` stub** — only needed because the
  *tcc-built* host gcc miscompiled GCC 4.7 `real.c` (FP-constant ICE). The
  stage-1 host gcc used here compiles the pristine file fine — verified it builds
  at `-O2 -fno-tree-ccp` with the freshly built stage-2 `xgcc`.

## Verification

Installed `bootstrap-gcc-2/opt/bin/g++` compiled and ran a C++11 test
(`bootstrap-gcc-2/cxxtest.cpp`: `std::vector` + `std::sort` + lambda comparator,
`throw`/`catch` of `std::runtime_error`, iostream double formatting):

```
beta=1 gamma=2 alpha=3      # vector sorted by lambda
exception: caught-ok        # libsupc++ unwinder works
double: 38.53               # iostream FP formatting correct
```

Link note: static musl, so link the new GCC's `libgcc.a`
(`$(gcc -print-libgcc-file-name)`) explicitly for the aarch64 128-bit
`long double` TFmode soft-float helpers; `-nostdlib`/`-static` otherwise drop it.
