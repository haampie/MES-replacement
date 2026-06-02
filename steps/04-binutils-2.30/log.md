# binutils 2.30 (musl-boot0) — bootstrap log

Following the recipe from `commencement.scm:1182` (`binutils-muslboot0`),
adapted to aarch64.

Inputs in the VM:
- TCC: `~/bootstrap-tcc-musl/tcc-musl-new` (the tcc-on-musl binary
  produced after the `arm64-long-suffix-64bit` parser patch; self-hosts
  byte-identically).
- libc: `~/bootstrap-musl/opt/musl` (musl 1.1.24 built per
  `steps/musl-1.1.24/build.sh`).
- `libtcc1.a` installed at `$MUSL/lib/tcc/libtcc1.a` (soft-float helpers
  from `lib-arm64.o`).

Source: `binutils-2.30.tar.gz` from gnu.org
(sha256 `8c3850195d1c093d290a716e20ebcaa72eda32abf5e3d8611154b39cff79e9ea`).

Working dir: `~/bootstrap-binutils/build/binutils-2.30/`, git-initialised
to track every patch as a commit.

## Pre-configure tweaks

Mirroring `commencement.scm` `fix-build` phase:
- `gas/read.c`: drop `#include "wchar.h"` (mes-libc has no wchar.h; musl
  does, but keep the patch parallel to the Guix recipe).
- `bfd/po/{install,all,info}`: create empty files so the recursive `po`
  make-rules become no-ops (bfd/po has no Makefile here).

## Configure

```
./configure \
    CC="tcc-musl-new -L$MUSL/lib" \
    LD=tcc-musl-new AR="tcc-musl-new -ar" RANLIB=true MAKEINFO=true \
    CFLAGS=-g \
    --build=aarch64-linux-musl --host=aarch64-linux-musl --target=aarch64-linux-musl \
    --prefix=$PREFIX --with-sysroot=/ \
    --enable-64-bit-bfd --disable-nls --enable-static --disable-shared \
    --disable-werror --disable-plugins --enable-deterministic-archives
```

Configure succeeded.

## Issues encountered

### 1. tcc preprocessor can't handle `#if` inside macro args

`bfd/elfnn-aarch64.c` (the source for the sed-substituted
`elf64-aarch64.c` / `elf32-aarch64.c`) has three HOWTO macro calls for
`TLS_DTPMOD`, `TLS_DTPREL`, `TLS_TPREL` whose `name` argument is
selected via `#if ARCH_SIZE == 64 / #else / #endif` *inside* the
HOWTO(...)  argument list.

tcc 0.9.26's preprocessor stops collecting macro arguments at the first
preprocessor directive — it keeps the args before the `#if` and drops
everything from `#if` through `#endif`, including subsequent args.  The
preprocessed output then has bare tokens like `64,` floating in the
middle of the `reloc_howto_type` array, producing
`error: '}' expected (got ",")`.

**Fix** (commit on the binutils branch): hoist the conditional name
selection into helper macros defined once at the top of the file
(`AARCH64_NAME_TLS_DTPMOD`, etc.), then reference those macros from
inside the HOWTO call.  Semantically identical, but no preprocessor
directive sits inside a macro argument list anymore.

### 2. Missing bison/flex/m4 in the build environment

binutils 2.30 ships pre-generated `sysinfo.c` and `syslex.c` but **not**
`arparse.c`/`defparse.c`/`rcparse.c`/`mcparse.c`, so a build from a
clean tarball needs bison/flex.  In the Guix bootstrap these come from
earlier in the chain; in our VM we just install the Ubuntu packages
(host bison/flex/m4 are fine — they don't enter the artifact, only the
generated `.c` files do).

### 3. autoconf's LEX_OUTPUT_ROOT detection breaks under `missing`

Configure's `AC_PROG_LEX` test invokes the `LEX` variable to discover
its output filename (`lex.yy.c`).  Because we passed
`LEX=$(builddir)/missing flex`, autoconf's test ran `missing flex` —
which prints a "flex is missing" diagnostic to stderr and exits non-zero
— so configure set `LEX_OUTPUT_ROOT=` (empty) as a fallback.  Then
during `make`, the `.l → .c` rule expands to

    ylwrap syslex.l .c syslex.c -- /usr/bin/flex

and ylwrap tries to rename "the file named `.c`" rather than `lex.yy.c`,
leaving `lex.yysyslex.c` on disk and `syslex.c` missing.  The next step
(`#include "syslex.c"` from `syslex_wrap.c`) then fails.

**Fix**: command-line override `LEX_OUTPUT_ROOT=lex.yy` is ignored once
the recursive sub-make picks up the cached value, so `sed -i` it in all
five sub-Makefiles (`{ld,binutils,binutils/doc,gas,gas/doc}/Makefile`).
Long-term better to either reconfigure with `LEX=/usr/bin/flex` from the
start, or patch the `missing` shim to be quieter so autoconf's probe
sees flex.

## Build result

`make` completes with exit 0.  Five host binaries produced:

| binary             | size       |
|--------------------|-----------:|
| `binutils/ar`      |   4.7 MB   |
| `binutils/nm-new`  |   4.6 MB   |
| `binutils/objdump` |   7.8 MB   |
| `gas/as-new`       |   7.4 MB   |
| `ld/ld-new`        |   8.8 MB   |

Total build time on the lima aarch64 VM: ~30 s.

## Runtime smoke test

Started, has issues:

- `as-new` segfaults assembling a 3-instruction test (`Internal error
  (Segmentation fault)`).
- `ld-new` segfaults on a tcc-produced `.o` (exit 139).
- `objdump` runs and disassembles existing object files.

## Issue 4: aarch64 tcc miscompiles forwarded `va_list` parameters

Root-caused with gdb on the `as-new` crash:

```
#0  0x000000000067... in strlen ()
#1  0x000000000064eb40 in vconcat_copy () at ./concat.c:77
#2  0x000000000064e8f0 in concat ()        at ./concat.c:152
#3  0x000000000040567c in parse_args ()    at as.c:559
#4  0x0000000000407b4c in main ()          at as.c:1220
```

`as.c:559` is the trivial `concat(std_shortopts, md_shortopts, NULL)`.
Inside `libiberty/concat.c`, `concat()` forwards its `va_list args` to
`static inline vconcat_length(... va_list args)` and then to
`vconcat_copy(... va_list args)`.  The first `va_arg` call inside the
forwardee returns a garbage pointer; `strlen` then dereferences it and
segfaults.

Minimal repro (`~/bootstrap-binutils/repro/vc2.c` in the VM):

```c
static void inner(va_list ap) {
    int a = va_arg(ap, int);     /* garbage */
    int b = va_arg(ap, int);
    int c = va_arg(ap, int);
    fprintf(stderr, "inner: %d %d %d\n", a, b, c);
}
static void outer(int n, ...) {
    va_list ap;
    va_start(ap, n);
    int a = va_arg(ap, int);     /* OK: 100 200 300 */
    int b = va_arg(ap, int);
    int c = va_arg(ap, int);
    fprintf(stderr, "outer direct: %d %d %d\n", a, b, c);
    va_end(ap);
    va_start(ap, n);
    inner(ap);                   /* prints garbage */
    va_end(ap);
}
int main(void) { outer(3, 100, 200, 300); }
```

### Mechanism

Our musl uses AAPCS64 array-form `va_list` (`struct __va_list_struct
va_list[1]`, see `steps/musl-1.1.24/patches/0016`).  tcc 0.9.26
aarch64 implements `__va_start`/`__va_arg` as builtins in
`arm64-gen.c` (`gen_va_start`/`gen_va_arg`).  Both begin with
`gaddrof()`:

  - For a **local** `va_list ap` (array type), `vtop->type.t` is
    `VT_PTR | VT_ARRAY` (`0x24`); `gaddrof` yields the array start —
    correct.
  - For a **parameter** declared `va_list ap`, the array decays to a
    pointer at declaration time per standard C, so `vtop->type.t` is
    plain `VT_PTR` (`0x4`).  `gaddrof` then takes the *address of the
    parameter slot* on the stack, not the pointer value the slot
    holds.  The subsequent `gen_va_arg` machine code reads
    `__gr_offs`/`__stack` from a random stack offset → garbage.

Verified by instrumenting `gen_va_arg` with a stderr trace of
`vtop->type.t` while compiling `vc2.c`:

```
GVA type.t=0x4   r=0x132 sym=...  VT_ARRAY=0   <-- inner (parameter)
GVA type.t=0x4   r=0x132 sym=...  VT_ARRAY=0
GVA type.t=0x4   r=0x132 sym=...  VT_ARRAY=0
GVS type.t=0x24  r=0x32  sym=...  VT_ARRAY=1   <-- outer (local)
GVA type.t=0x24  r=0x32  sym=...  VT_ARRAY=1
```

### Fix

Two simple-patches under `steps/tcc-0.9.26/simple-patches/` skip the
`gaddrof` on the parameter (already-pointer) path:

- `arm64-va-start-param-decay.{before,after}`
- `arm64-va-arg-param-decay.{before,after}`

Wired into `steps/tcc-0.9.26/pass1.kaem` next to
`arm64-long-suffix-64bit`.  After re-running the kaem chain to
regenerate `/usr/bin/tcc` (and bumping `tcc-0.9.26.arm64.checksums`),
musl + `tcc-musl` + binutils need to be rebuilt in order on top.

## Status: fix wired into seed tcc, awaits full-chain rebuild

Next: re-run `task5_arm64.sh` with `UPDATE_CHECKSUMS=True` (same
procedure as the `arm64-long-suffix-64bit` rollout — see
`steps/musl-1.1.24/log.md` "Resolution: kaem rebuild + full chain"),
then rebuild musl → tcc-musl → binutils, and confirm
`as-new`/`ld-new` no longer segfault on the repro fixtures.

## (Previous parked state — superseded by Issue 4 above)

Build path is captured and the patches are committed.  Next milestone is
`gcc-mesboot0` (also from `commencement.scm`) — but that needs the
initial gcc seed, which depends on much more (m4, mpfr, etc. as
prerequisites of `gmp-boot`).  Worth thinking through whether the chain
makes sense for our VM target before continuing.
