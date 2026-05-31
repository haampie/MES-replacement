#!/bin/sh
# Notes-only build script for musl 1.1.24 on aarch64 using tcc 0.9.26.
#
# Not yet wired into the kaem chroot bootstrap: the chroot at this stage
# has neither GNU make nor a POSIX shell rich enough to run configure
# scripts.  Keep this as a record of the exact sequence that produces a
# working static libc.a + crt*.o, validated outside the chroot (Linux VM
# with host coreutils + GNU make).
#
# Inputs assumed in the environment:
#   TCC         path to tcc 0.9.26 (aarch64), produced by steps/tcc-0.9.26
#   PREFIX      install prefix for the resulting libc
#   SYSROOT     prefix containing Linux uapi headers (asm/, linux/, ...)
#   DISTFILES   directory holding musl-1.1.24.tar.gz
#   PATCHDIR    this directory's patches/ subdir

set -ex

# 1. Extract pristine tarball.
tar -xf "${DISTFILES}/musl-1.1.24.tar.gz"
cd musl-1.1.24

# 2. Apply the patch series in order.  These cover:
#    - tcc 0.9.26 has no aarch64 instruction assembler -> rewrite every
#      .s file as a .c emitting raw .int instruction words (patches 5, 7,
#      14, 21).  Encodings verified with llvm-mc.
#    - tcc has no inline-asm operand constraints -> drop reorder barriers
#      and LL/SC atomics, route TLS through out-of-line wrappers
#      (patches 8, 9, 10, 11, 15).
#    - tcc va_arg differs from gcc: synthesise musl's va_list via tcc's
#      __va_start/__va_arg builtins (patches 3, 13, 16-19).
#    - Files tcc cannot compile at all are simply removed: complex math,
#      static-PIE startup, aarch64 math shims (patches 2, 4, 14).
#    - tcc -ar refuses empty archives -> EMPTY_LIBS get a placeholder .o
#      (patches 1, 20).  Note: patch 20 only changes how empty.o is
#      *consumed*; nothing generates obj/empty.o, hence step 5 below.
for p in "${PATCHDIR}"/*.patch; do
    patch -p1 < "$p"
done

# 3. Configure.  --disable-shared avoids needing a working dynamic
# loader; --disable-gcc-wrapper since the wrapper assumes gcc-style
# argument handling tcc doesn't share.
./configure \
    CC="${TCC}" \
    --target=aarch64-linux-musl \
    --prefix="${PREFIX}" \
    --syslibdir="${PREFIX}/lib" \
    --disable-shared \
    --disable-gcc-wrapper

# 4. The Makefile expects obj/empty.o for the empty libs (libg.a etc.).
# musl ships no source file for it and the upstream Makefile has no rule
# to generate one; patch 20 only wires it into the AR command.  Generate
# it by hand from an empty .c.
mkdir -p obj
: > /tmp/musl-empty.c
"${TCC}" -c -o obj/empty.o /tmp/musl-empty.c

# 5. Build.  -DSYSCALL_NO_TLS because tcc has no __thread storage class.
# AR="tcc -ar" and RANLIB=true because tcc bundles its own ar and the
# resulting archives need no index.
make -j1 \
    CC="${TCC}" \
    AR="${TCC} -ar" \
    RANLIB=true \
    CFLAGS="-DSYSCALL_NO_TLS -I${SYSROOT}/include"

make install \
    CC="${TCC}" \
    AR="${TCC} -ar" \
    RANLIB=true

# 6. Smoke test (caller's responsibility): link a static hello-world
# against ${PREFIX}/lib/{crt1.o,crti.o,libc.a,crtn.o} and run it.
