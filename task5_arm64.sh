#!/bin/sh
# Fully-aarch64 chroot bootstrap of tcc 0.9.26. The arm64 analogue of
# task5_amd64.sh: it builds the seed artifacts with `make`, assembles a rootfs
# using the SAME generic layout the amd64 path uses, and runs the SAME shared
# steps/ pipeline (configurator + script-generator + steps/tcc-0.9.26/pass1.kaem)
# inside a chroot. There is no cross step and no host-side patching: every
# binary that runs in the chroot is an aarch64 static ELF, and the tcc source
# patches are applied in-chroot by the chroot-built simple-patch.
#
# On aarch64 hardware this runs natively (like amd64). On an x86_64 dev host,
# register the qemu-aarch64 binfmt handler with the F (fix-binary) flag first so
# the rootfs needs no qemu binary, e.g.:
#   sudo apt install qemu-user-static binfmt-support   # or your distro's pkgs
#   ls /proc/sys/fs/binfmt_misc/qemu-aarch64            # confirm it is registered
#
# The aarch64-enabled GNU Mes libc is distributed as distfiles/mes-0.27.1-aarch64.tar.gz
# (a git archive of the mes submodule; regenerate with:
#   git -C mes archive --format=tar --prefix=mes-0.27.1/ HEAD | gzip -n \
#       > distfiles/mes-0.27.1-aarch64.tar.gz ).

set -x

#############################################################################
# Phase A: build the seed/cross tools and the aarch64 seed artifacts
#############################################################################
# The generator tools (tcc_cc, stack_c, blood-elf, M1, hex2) are gcc-built and
# native to the build host; `make arm64` uses them to emit the aarch64 seed
# artifacts. On aarch64 hardware everything here is aarch64 (no cross).
make -C src tcc_cc stack_c_arm64 blood-elf M1 hex2
make -C src arm64

#############################################################################
# Phase B: assemble the rootfs (generic amd64-style layout)
#############################################################################
rm -rf rootfs
mkdir -p rootfs
mkdir -p rootfs/usr
mkdir -p rootfs/usr/bin
mkdir -p rootfs/tmp

# Bootstrap seeds (aarch64 static ELFs: the irreducible starting binaries).
mkdir -p rootfs/bootstrap-seeds/POSIX/AArch64
cp -f src/kaem-minimal.arm64 rootfs/bootstrap-seeds/POSIX/AArch64/kaem-optional-seed
cp -f src/hex0.arm64         rootfs/bootstrap-seeds/POSIX/AArch64/hex0-seed

# Root kaem script.
cp -f target_arm64/kaem.arm64 rootfs/kaem.arm64

# arm64-specific directory: phase scripts + committed seed assemblies, staged
# under the GENERIC names the shared pipeline expects (hex0.hex0, stack_c.M1,
# stack_c_intro.M1, ELF-arm64-debug.hex2, ...).
mkdir -p rootfs/arm64
mkdir -p rootfs/arm64/artifact
cp -f -t rootfs/arm64 \
    target_arm64/tools-seed-kaem.kaem \
    target_arm64/tools-mini-kaem.kaem \
    target_arm64/check-tools.kaem \
    target_arm64/tools-kaem.kaem \
    target_arm64/after.kaem
# M2libc ships the header as aarch64; rename on copy to keep the ${ARCH} template
# uniform (hex2 is agnostic to the file name).
cp -f M2libc/aarch64/ELF-aarch64-debug.hex2 rootfs/arm64/ELF-arm64-debug.hex2
cp -f src/hex0.arm64_hex0           rootfs/arm64/hex0.hex0
cp -f src/kaem-minimal.arm64_hex0   rootfs/arm64/kaem-minimal.hex0
cp -f src/hex2.arm64_hex0           rootfs/arm64/hex2.hex0
cp -f src/blood-elf.macro_arm64     rootfs/arm64/blood-elf.macro
cp -f src/blood-elf.blood_elf_arm64 rootfs/arm64/blood-elf.blood_elf
cp -f src/M1.macro_arm64            rootfs/arm64/M1.macro
cp -f src/M1.blood_elf_arm64        rootfs/arm64/M1.blood_elf
cp -f src/stack_c_arm64.M1_arm64    rootfs/arm64/stack_c.M1
cp -f src/stack_c_intro_arm64.M1    rootfs/arm64/stack_c_intro.M1

# Generic source files (compiled inside the chroot). Mirrors task5_amd64.sh, with
# arm64-asm.c added for the in-chroot tcc inline-asm patch.
mkdir -p rootfs/src
cp -f -t rootfs/src \
    src/stdlib.c \
    src/sys_syscall.h \
    src/tcc_cc.sl64a \
    src/kaem.c \
    src/catm.c \
    src/bootstrappable.c \
    src/match.c \
    src/mkdir.c \
    src/cp.c \
    src/chmod.c \
    src/rm.c \
    src/untar.c \
    src/ungz.c \
    src/unxz.c \
    src/unbz2.c \
    src/sha256sum.c \
    src/configurator.c \
    src/script-generator.c \
    src/stack_c_interpreter.c \
    src/arm64-asm.c

# Source files used by the check-tools.kaem reproducibility self-test.
cp -f -t rootfs/src \
    src/equal.c \
    src/hex0.c \
    src/hex2.c \
    src/blood-elf.c \
    src/M1.c \
    src/stack_c_arm64.c \
    src/tcc_cc.c \
    src/kaem-minimal.c

# Scripts for the steps-processing phase.
cp -f target_arm64/seed.kaem rootfs

# Steps pipeline + arm64 bootstrap config + arm64 manifest (tcc-0.9.26 only).
cp -r steps rootfs
cp -f target_arm64/bootstrap.cfg rootfs/steps
cp -f target_arm64/manifest rootfs/steps/manifest

# Distribution files (incl. the aarch64 mes tarball and the tcc tarball).
mkdir rootfs/external
cp -r distfiles rootfs/external

#############################################################################
# Phase C: run the bootstrap inside the chroot
#############################################################################
# Numeric uid:gid (the rootfs has no /etc/passwd, so a username can't be resolved).
sudo chroot --userspec=$(id -u):$(id -g) rootfs \
    /bootstrap-seeds/POSIX/AArch64/kaem-optional-seed kaem.arm64
