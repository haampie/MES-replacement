#!/bin/sh
# Notes-only build script for binutils 2.30 on aarch64 using tcc-musl.
# Mirrors commencement.scm `binutils-muslboot0`.
#
# Inputs (env):
#   TCC         path to tcc-musl (the tcc-on-musl binary with the
#               arm64-long-suffix-64bit parser patch baked in)
#   MUSL        prefix containing musl libc.a + crt*.o (and lib/tcc/libtcc1.a)
#   PREFIX      install prefix for binutils
#   DISTFILES   dir holding binutils-2.30.tar.gz
#   PATCHDIR    this dir's patches/ subdir
#
# Host tools used as-is (don't end up in any artifact):
#   make, sed, awk, bash, bison, flex, m4

set -ex

tar -xf "${DISTFILES}/binutils-2.30.tar.gz"
cd binutils-2.30

# Apply our patch series.
for p in "${PATCHDIR}"/*.patch; do
    patch -p1 --batch < "$p"
done

./configure \
    CC="${TCC} -L${MUSL}/lib" \
    LD="${TCC}" \
    AR="${TCC} -ar" \
    RANLIB=true \
    MAKEINFO=true \
    LEX=/usr/bin/flex \
    YACC="/usr/bin/bison -y" \
    M4=/usr/bin/m4 \
    CFLAGS=-g \
    --build=aarch64-linux-musl \
    --host=aarch64-linux-musl \
    --target=aarch64-linux-musl \
    --prefix="${PREFIX}" \
    --with-sysroot=/ \
    --enable-64-bit-bfd \
    --disable-nls \
    --enable-static \
    --disable-shared \
    --disable-werror \
    --disable-plugins \
    --enable-deterministic-archives

# autoconf's AC_PROG_LEX failed to detect lex.yy as the output root
# (because LEX was the `missing flex` shim during configure-time tests),
# leaving LEX_OUTPUT_ROOT='' in every sub-Makefile.  Fix it by hand —
# can't override on the make command line because the recursive
# sub-make resets it.
find . -name Makefile -exec sed -i 's|^LEX_OUTPUT_ROOT = $|LEX_OUTPUT_ROOT = lex.yy|' {} +

make -j1 \
    MAKEINFO=true \
    M4=/usr/bin/m4 \
    BISON=/usr/bin/bison \
    YACC="/usr/bin/bison -y" \
    FLEX=/usr/bin/flex \
    LEX=/usr/bin/flex

make install \
    MAKEINFO=true \
    M4=/usr/bin/m4 \
    BISON=/usr/bin/bison \
    YACC="/usr/bin/bison -y" \
    FLEX=/usr/bin/flex \
    LEX=/usr/bin/flex
