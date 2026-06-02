#!/bin/sh
# Build GNU make 4.4.1 with the seed tcc 0.9.26 (mes libc), aarch64.
#
# Status: validated on the host (Linux aarch64 with host coreutils + a host
# GNU make + POSIX sh to run ./configure).  NOT yet wired into the kaem chroot:
# at the seed-tcc stage the chroot has neither a POSIX shell nor a make, so
# configure cannot run there.  Like steps/musl-1.1.24/build.sh, this is the
# exact, reproducible sequence -- only the *compiler* is the seed tcc.
#
# Dependencies: ONLY step 01 (seed tcc 0.9.26 + mes libc).  Does not need musl,
# binutils, or gcc.  This is the "fifo-jobserver-aware make, early" experiment.
#
# Inputs:
#   ROOTFS     MES-replacement chroot tree (seed tcc at usr/bin/tcc, mes libc
#              at usr/{lib,include}/mes).  Defaults via mes-tcc to ../../rootfs.
#   DISTFILES  dir holding make-4.4.1.tar.gz (see ./sources for URL+sha256).

set -ex
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${DISTFILES:=$HERE}"

# 1. Unpack.
tar -xf "${DISTFILES}/make-4.4.1.tar.gz"
cd make-4.4.1

# 2. Configure with the seed tcc as the C compiler.  --disable-load drops the
# dynamic-objects (-ldl/dlopen) feature; --without-guile and --disable-nls keep
# the dependency surface minimal.  configure correctly detects the many libc
# functions mes lacks and arranges gnulib replacements for them.
./configure CC="${HERE}/mes-tcc" --disable-nls --without-guile --disable-load

# 3. Build the mes-libc compatibility object (see mes-compat.{c,h} and
# mes-libc-fixes.md).  It supplies macros/structs/functions missing from mes
# libc, fixes the assert/NDEBUG mismatch, and -- crucially -- overrides the
# aarch64-broken opendir/readdir/closedir so make can list directories and
# enables mkfifo so the fifo jobserver compiles in.
"${HERE}/mes-tcc" -g -include "${HERE}/mes-compat.h" -c "${HERE}/mes-compat.c" -o "${HERE}/mes-compat.o"

# 4. Build make.  mes-compat.h is force-included into every TU; mes-compat.o is
# linked in (object symbols override the buggy libc.a archive members).
make \
    CFLAGS="-g -include ${HERE}/mes-compat.h" \
    LDFLAGS="${HERE}/mes-compat.o"

# 5. Result: ./make is a static aarch64 binary.  Smoke test:
./make --version
./make -p -f /dev/null 2>/dev/null | grep -q jobserver-fifo \
    && echo "OK: fifo jobserver compiled in"
