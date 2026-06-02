# 06 — musl 1.1.24, rebuilt by GCC (pristine, zero patches)

The real libc of the chain: **pristine musl 1.1.24 with ZERO source patches**,
compiled by the stage-1 GCC. Replaces the tcc-built scaffold musl
(`../musl-1.1.24`, 21 tcc patches), which is discarded once this exists.

- **Source:** same tarball as the scaffold step — `musl-1.1.24.tar.gz`
  (see `../musl-1.1.24/sources` / checksum). Clean tree:
  `bootstrap-musl-gcc/build-clean/musl-1.1.24`.
- **Patches:** none. Every one of the 7 patches the *old* FP-buggy-GCC build
  needed (complex-math, floatscan, decfloat, `rem_pio2_large`, `scalbnl`,
  `exp10`, `drand48`) was a `HAVE_FLOAT` artifact and is unnecessary with the
  fixed GCC.
- **Install prefix:** `bootstrap-musl-gcc/opt/musl` (`libc.a` ≈ 2.7 MB).
- **Raw build log:** `bootstrap-musl-gcc/LOG.md` (318 lines).

## Built twice (mirrors the stage-1 v1/v2 loop)

| | host CC (built it) | tree | note |
|---|---|---|---|
| v1 | stage-1 **v1** (`bootstrap-gcc/opt`) | `build-clean` | proves the chain self-consistent; provides the sysroot stage-1 **v2** is configured against |
| v2 | stage-1 **v2** (`bootstrap-gcc/opt-muslsysroot`) | `build-newgcc` | **installed** at `opt/musl`; descends only from the pristine-sysroot toolchain (no tcc-scaffold lineage) |

The installed `opt/musl` is **v2**. Provenance check: `bits/alltypes.h` has
`typedef __builtin_va_list va_list`; `libc.a` dated from the `build-newgcc` run.

## Build commands

Configure (musl's own; detects cross prefix → `CROSS_COMPILE=aarch64-linux-musl-`,
so AR/RANLIB resolve to the **bootstrap-binutils** tools on PATH, never system):

```
./configure CC=bootstrap-gcc/opt-muslsysroot/bin/gcc CFLAGS=-fno-tree-ccp \
    --target=aarch64-linux-musl \
    --prefix=bootstrap-musl-gcc/opt/musl \
    --syslibdir=bootstrap-musl-gcc/opt/musl/lib
make && make install
```

- `CFLAGS=-fno-tree-ccp` — default `-Os` segfaults cc1 on `src/aio/aio.c`
  (the same CCP/TImode backend bug); musl appends user CFLAGS after `CFLAGS_AUTO`
  so `-Os` stays in effect. Not FP, not tcc.

## Verification

Hello-world linked against `opt/musl` prints `printf("%f", 38.53)` →
**`38.530000`**; `%g`, `%e`, `%.2f`, `(long)d` all correct. (The seed-tcc
scaffold musl printed `0.00`.) Link `$(gcc -print-libgcc-file-name)` for the
aarch64 128-bit `long double` TFmode soft-float helpers — normal aarch64
behaviour, not a defect.
