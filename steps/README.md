# Bootstrap chain steps

Each chain step has its own directory with a `log.md` (prose build log),
`sources` (URL + sha256), and `patches/` where applicable.

## Order

| # | Dir | What | Built by |
|---|-----|------|----------|
| 01 | `tcc-0.9.26` | seed tcc 0.9.26 on **mes libc** (aarch64) | tcc_cc.c / kaem |
| 02 | `musl-1.1.24` | stage-1 *scaffold* musl (21 tcc patches) | seed tcc |
| 03 | `03-tcc-musl` | tcc **0.9.26 rebuilt on musl** → `tcc-musl-stage3` | seed tcc + scaffold musl |
| 04 | `04-binutils-2.30` | `as`/`ld`/`ar` etc. | tcc-musl-stage3 |
| 05 | `05-gcc-4.7-stage1` | GCC 4.7.4, **C only** | tcc-musl-stage3 |
| 06 | `06-musl-1.1.24-gcc` | **pristine** musl, zero patches (the real libc) | stage-1 GCC |
| 07 | `07-gcc-4.7-stage2` | GCC 4.7.4, **C + C++** (final) | stage-1 GCC + pristine musl |
| 08 | `08-gmake-4.4.1` | GNU make 4.4.1 (fifo jobserver) — *optional side-branch* | **seed tcc only** |

Step **08 is an optional side-branch**, not on the GCC critical path. It depends
only on step 01 (seed tcc 0.9.26 + mes libc) and is numbered last merely because
it was added last — conceptually it can be built right after the seed tcc. It
also doubles as the record of several **mes libc aarch64 bugs/gaps** found along
the way: see `08-gmake-4.4.1/mes-libc-fixes.md` (the `opendir`/`O_DIRECTORY`
bug, `assert`/`NDEBUG`, missing `mkfifo`/`ftruncate`/`tmpfile`, etc.).

There is **no tcc 0.9.27 build** — the chain uses tcc 0.9.26 throughout (first on
mes libc, then on musl). The leftover `tcc-0.9.27/` dir is referenced only by the
`manifest` files (and its `rootfs/` copy); it is legacy and is **not** an actual
build step. Do not treat it as one.

`gcc-bootstrap-notes.md` is the cross-cutting narrative linking 05–07.

## Numbering convention

Steps **01 and 02** keep their bare names on purpose: they are wired into the
kaem build scripts (`tcc-0.9.26/pass1.kaem`, `bootstrap.cfg`, `manifest`, …) by
path, so renaming them would break `task5_arm64.sh`. They are conceptually 01/02.

Steps **03–07** are built by hand (outside kaem) and nothing references their
paths, so they carry numeric `NN-` prefixes for readability. The non-step helper
dirs (`env`, `manifest`, `simple-patch-1.0`, `checksum-transcriber-1.0`) are
tooling, not chain steps, and are left unprefixed.
