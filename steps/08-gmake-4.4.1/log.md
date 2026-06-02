# 08 — GNU make 4.4.1, built by the seed tcc 0.9.26 (mes libc)

**Optional / side-branch step.** Numbered 08 only because it was authored after
the GCC chain was complete. Its *only* dependency is **step 01** (the seed tcc
0.9.26 + mes libc); it does **not** use musl, binutils, or gcc. Conceptually it
sits right after the seed tcc — the point being to get a **fifo-jobserver-aware
`make` available early** in the bootstrap.

Result: a static aarch64 `make` 4.4.1 that runs, self-discovers `Makefile`, and
drives parallel builds through a real **fifo jobserver** (`--jobserver-auth=
fifo:…`), inherited correctly by recursive sub-makes. `.FEATURES` lists
`jobserver jobserver-fifo`. Everything was compiled by the seed tcc against mes
libc only — verified that every header comes from `rootfs/usr/include/mes`
(none from the host `/usr/include`) and the link uses mes `crt*.o`, `libc.a`,
`libtcc1.a` exclusively.

4.4 (not 4.2.x) because the named-pipe/fifo jobserver style was introduced in
make 4.4; 4.2.1 only has the anonymous-pipe jobserver.

## How it was built

Same arrangement as `steps/musl-1.1.24/build.sh`: the host `sh`/`make`/
`configure` only *orchestrate*; the **compiler is the seed tcc**, via the
`mes-tcc` wrapper (adds mes include/lib dirs and, on link, the mes
`crt1/crti/libc/libtcc1/crtn` under `-nostdlib`). See `build.sh`. Files:

- `mes-tcc` — the cc wrapper around `rootfs/usr/bin/tcc`.
- `mes-compat.h` — force-included (`-include`) into every TU; supplies macros,
  structs, prototypes, the NDEBUG-honoring `assert`, and the
  `opendir/readdir/closedir` redirect.
- `mes-compat.c` → `mes-compat.o` — implementations of the libc functions mes
  lacks (`ftruncate`, `tmpfile`, `mkfifo`) and **corrected**
  `mes_opendir/mes_readdir/mes_closedir`. Linked in; object symbols win over
  the buggy `libc.a` members.

No edits were made to make's own source — all adaptation lives in the two
compat files. `build.sh` step 4 is the whole build.

## What mes libc was missing / wrong (worked around here)

Full upstream-fix detail is in **`mes-libc-fixes.md`** (written so the mes libc
maintainer can fix these at the source). Summary of what gmake hit:

1. **`opendir` broken on aarch64 (the big one).** mes `opendir` passes the
   *x86_64* value of `O_DIRECTORY` (`0x10000`), which on aarch64/asm-generic is
   `O_DIRECT` → kernel returns `EINVAL` → **every `opendir()` fails**. make's
   `file_exists_p()` is readdir-based, so make couldn't even find its own
   `Makefile` (implicit search reported "no makefile found" although
   `stat("Makefile")` succeeded). Worked around by overriding the dir trio with
   a correct `getdents64`-based implementation (`O_DIRECTORY = 0x4000`); the
   kernel `linux_dirent64` layout matches mes `struct dirent` on aarch64, so
   records pass straight through.
2. **`assert` ignores `NDEBUG`.** make defines `NDEBUG` (makeint.h) and relies
   on `assert()` vanishing; mes keeps it live, so variables used only inside
   asserts (under `#ifndef NDEBUG`) disappeared while the asserts referencing
   them stayed → "undeclared" (e.g. `implicit.c:655 'dend'`). Supplied a no-op
   `assert`.
3. **POSIX decls hidden** unless `BOOTSTRAP_WITH_POSIX` is defined — without it,
   `getcwd`/`_POSIX_VERSION` are absent and makeint.h emits a clashing legacy
   `char *getcwd(void)` prototype.
4. **Missing macros/types:** `O_CLOEXEC`, `O_NONBLOCK`, `ENOTSUP`, `DT_*`
   (dirent types), `struct flock` + `F_RDLCK/F_WRLCK/F_UNLCK/F_SETLK*`.
5. **Missing functions:** `ftruncate`, `tmpfile`, `mkfifo` (added via raw
   syscalls). `mkfifo` (via `mknodat`) + defining `HAVE_MKFIFO` is what turns
   the **fifo jobserver** on. `mktemp` exists in `libc.a` but had no prototype.
6. **`printf`/stdio is fully unbuffered** — one `write(2)` per byte. Correct but
   extremely slow. Not a blocker; noted for efficiency.

## Verifying it works

```sh
cd steps/08-gmake-4.4.1 && ./build.sh        # builds make-4.4.1/make
MK=$PWD/make-4.4.1/make
mkdir /tmp/t && cd /tmp/t
printf 'all: a b c d\na b c d:\n\t@echo $@; sleep .2\n' > Makefile
"$MK" -j4 all          # implicit Makefile discovery + fifo jobserver, parallel
"$MK" -p -f /dev/null | grep jobserver-fifo
```
