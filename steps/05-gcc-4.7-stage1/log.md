# 05 — GCC 4.7 (Linaro 4.7.4) aarch64, stage 1 (C only)

The first real C compiler of the chain: GCC 4.7.4 built **by tcc**
(`tcc-musl-stage3`), C-only, static. It exists to (a) recompile musl correctly
(see `06-musl-1.1.24-gcc`) and (b) host the stage-2 C+C++ build
(`07-gcc-4.7-stage2`).

- **Source:** same Linaro tarball as stage 2 — `gcc-linaro-4.7-2013.11.tar.bz2`
  (see `../07-gcc-4.7-stage2/sources`). Worktree `bootstrap-gcc/src/gcc-linaro-4.7-2013.11`.
- **Only patch:** `0001` alloca rename (`../07-gcc-4.7-stage2/patches/0001-*.patch`).
  Stage 1 needs nothing else: every other historical workaround was a `HAVE_FLOAT`
  artifact removed when tcc was rebuilt with `-DHAVE_FLOAT=1`.
- **GMP/MPFR/MPC:** prebuilt in `bootstrap-gcc/prereqs` (GMP `--disable-assembly`,
  a tcc-assembler limitation).
- **Raw build log:** `bootstrap-gcc/LOG.md` (236 lines, per-package detail).

## Two-iteration bootstrap loop (Guix gcc-muslboot0 → gcc-muslboot)

Stage 1 is built **twice**, because its baked-in `--with-sysroot` decides which
musl `va_list` every host object sees:

| | compiler | host CC | `--with-sysroot` | prefix |
|---|---|---|---|---|
| v1 | gcc-muslboot0 | `tcc-musl-stage3` | scaffold musl (`bootstrap-musl/opt/musl-new`) | `bootstrap-gcc/opt` |
| v2 | gcc-muslboot  | `tcc-musl-stage3` | **pristine** musl v1 (`bootstrap-musl-gcc/opt/musl`) | `bootstrap-gcc/opt-muslsysroot` |

- **v1** is what first recompiles musl correctly (proves the `%f`→`0.00` defect
  was the seed tcc, not the compiler — see `gcc-bootstrap-notes.md`).
- The scaffold musl declares `va_list` the tcc way (`__musl_va_list_t[1]`), so v1
  bakes that in. That clashes with GCC's `struct __va_list` when v1 is used as a
  *host* compiler for stage 2 (`stdarg.h:102: conflicting types for 'va_list'`).
- **v2** is rebuilt with `--with-sysroot=` the pristine gcc-built musl (whose
  `va_list` is `__builtin_va_list`, identical to `__gnuc_va_list`) plus
  `--with-native-system-header-dir=/include` (pristine musl puts headers in
  `/include`, not `/usr/include`). With v2 as the stage-2 host CC the conflict
  vanishes — so the old stdarg `__DEFINED_va_list` patch (0002) was dropped.

**v2 is the stage-1 compiler used for everything downstream.** v1's `opt` is kept
only for provenance.

## Configure (v2 — the one that matters), build dir `bootstrap-gcc/build-muslsysroot`

```
CC=tcc-musl-stage3 AR=ar AS=as RANLIB=ranlib NM=nm   # ar/as/ranlib/nm = bootstrap-binutils on PATH
CFLAGS=-DHAVE_ALLOCA_H
--prefix=bootstrap-gcc/opt-muslsysroot
--build/--host/--target=aarch64-unknown-linux-musl
--with-sysroot=bootstrap-musl-gcc/opt/musl --with-native-system-header-dir=/include
--with-gmp/--with-mpfr/--with-mpc=bootstrap-gcc/prereqs
--enable-languages=c --enable-static --disable-shared
--enable-threads=single --disable-threads --disable-libstdcxx-pch
--disable-build-with-cxx --disable-bootstrap --disable-multilib
--disable-decimal-float --disable-lto --disable-lto-plugin --disable-plugin
--disable-{libatomic,libcilkrts,libgomp,libitm,libmudflap,libquadmath,libsanitizer,libssp,libvtv}
```

Build flag: `make … CFLAGS_FOR_TARGET="-O2 -fno-tree-ccp"` — genuine
GCC-4.7-aarch64 CCP/TImode backend segfault (`__cmpti2`/`__ucmpti2`); not tcc,
not FP, also hits user code.

## Verification

A hello-world compiled by v1 against pristine musl prints
`printf("%f", 38.53)` → `38.530000` (the scaffold musl printed `0.00`), and
`(long)d`, `d*2.0+f`, varargs `double` are all correct — the produced compiler
is sound even though the *scaffold libc* it was built against had a broken `%f`.
