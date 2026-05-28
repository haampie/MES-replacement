# arm64 (aarch64) TCC bootstrap

This documents the aarch64 port of the seed bootstrap of tcc 0.9.26. The port
follows the established x86_64 (amd64) method as closely as possible: a
live-bootstrap-style build *from nothing* inside a chroot, with no cross step and
no host-side work leaking into the bootstrap. Every binary that runs in the
chroot is an aarch64 static ELF, and the tcc source patches are applied
in-chroot.

The driver is **`task5_arm64.sh`**, the arm64 analogue of `task5_amd64.sh`. It
builds the seed artifacts with `make`, assembles a rootfs using the *same*
generic layout the amd64 path uses, and runs the *same* shared `steps/` pipeline
(`configurator` + `script-generator` + `steps/tcc-0.9.26/pass1.kaem`) inside the
chroot. There is no bespoke arm64 boot loop: the retired `target_arm64/kaem.run`
has been replaced by the full `target_amd64/`-shaped set under `target_arm64/`.

The engineering specific to aarch64 — the Stack-C backend, the runtime prologue,
the mes libc primitives, the va_list handling, and `setjmp`/`longjmp` — is
described in the three "milestone" sections below; those facts are properties of
the port and are independent of the driver.

## How it maps onto the amd64 path

| amd64 | arm64 | notes |
| --- | --- | --- |
| `task5_amd64.sh` | `task5_arm64.sh` | near-clone, AArch64 substituted |
| `target_amd64/` | `target_arm64/` | `kaem.arm64`, `tools-{seed,mini}-kaem.kaem`, `check-tools.kaem`, `tools-kaem.kaem`, `seed.kaem`, `after.kaem`, `bootstrap.cfg`, `manifest` |
| `steps/tcc-0.9.26/pass1.kaem` | same file | arm64 specifics folded in behind `match ${ARCH} arm64` guards |
| `mes-0.27.1.tar.gz` | `mes-0.27.1-aarch64.tar.gz` | a distfile (not a submodule overlay) carrying the aarch64 libc |

All `pass1.kaem` changes are guarded by `match ${ARCH} arm64`, so amd64 / x86 /
riscv64 are untouched. The shared steps pipeline was already arch-parameterized
(`MES_ARCH` / `TCC_TARGET_ARCH` / `HAVE_LONG_LONG`); arm64 just adds its own
branch.

### One arm64-only subtlety in the shared scripts

`tcc_cc -a arm64` only switches code generation to 64-bit — it does **not**
`#define TCC_TARGET_ARM64`. But `src/sys_syscall.h` selects the aarch64 syscall
numbers on `#elif defined(TCC_TARGET_ARM64)`, otherwise falling through to the
x86_64 numbers. So every in-chroot arm64 compile that pulls in `sys_syscall.h`
must pass **both** `-a arm64` and `-D TCC_TARGET_ARM64=1`. This is why the arm64
branches in `steps/checksum-transcriber-1.0/pass1.kaem`,
`steps/simple-patch-1.0/pass1.kaem`, and the `target_arm64/*.kaem` scripts all
carry the explicit `-D TCC_TARGET_ARM64=1`.

## Prerequisites

- **Native aarch64 Linux** host with `gcc`, `make`, `tar`, and `sudo` (for the
  chroot). This is the intended run target; the bootstrap is fully native.
- Submodules initialized and the tcc tarball present:

```sh
git submodule update --init --recursive
ls distfiles/tcc-0.9.26.tar.gz distfiles/mes-0.27.1-aarch64.tar.gz
```

The aarch64-enabled GNU Mes libc is distributed as
`distfiles/mes-0.27.1-aarch64.tar.gz` (a git archive of the `mes` submodule).
Regenerate it with:

```sh
git -C mes archive --format=tar --prefix=mes-0.27.1/ HEAD | gzip -n \
    > distfiles/mes-0.27.1-aarch64.tar.gz
```

### Iterating on an x86_64 dev host (optional crutch)

The bootstrap can be exercised on an x86_64 box via qemu-user binfmt — useful for
development, not part of the method. Register the aarch64 handler with the `F`
(fix-binary) flag so the rootfs needs no qemu binary inside it:

```sh
sudo apt install qemu-user-static binfmt-support   # or your distro's packages
ls /proc/sys/fs/binfmt_misc/qemu-aarch64            # confirm it is registered
```

On native aarch64 hardware none of this is needed.

## Run

```sh
./task5_arm64.sh
```

The script:

1. `make -C src tcc_cc stack_c_arm64 blood-elf M1 hex2` then `make -C src arm64`
   — builds the generator tools and the aarch64 seed artifacts. On native
   aarch64 every artifact is aarch64 (no cross).
2. Assembles `rootfs/` using the generic amd64-style names the shared pipeline
   expects (`hex0.hex0`, `kaem-minimal.hex0`, `stack_c.M1`, `stack_c_intro.M1`,
   `ELF-arm64-debug.hex2` from `M2libc/aarch64/ELF-aarch64-debug.hex2`, …), copies
   the generic C sources, the `steps/` pipeline, the arm64 `bootstrap.cfg` /
   `manifest`, and the distfiles.
3. Runs the bootstrap in a chroot:

```sh
sudo chroot --userspec=$(id -u):$(id -g) rootfs \
    /bootstrap-seeds/POSIX/AArch64/kaem-optional-seed kaem.arm64
```

(A numeric uid:gid is used because the rootfs has no `/etc/passwd`.)

### What runs inside the chroot

`kaem.arm64` is the 4-phase driver mirroring `kaem.amd64`:

1. **`tools-seed-kaem.kaem`** — the irreducible seeds (`hex0`, `kaem-minimal`).
2. **`tools-mini-kaem.kaem`** — `hex2`, `blood-elf`, `M1`, `stack_c`, `tcc_cc`,
   and a full `kaem`, all rebuilt from source.
3. **`check-tools.kaem`** — the native reproducibility self-test: each seed is
   rebuilt from its `.c` and `equal`-compared to the committed seed. (This
   replaces the off-chroot Makefile self-test diffs, which couldn't run on an
   x86_64 host.)
4. **`tools-kaem.kaem`** — `catm`, `match`, `sha256sum`, `mkdir`, `cp`, `chmod`,
   `rm`, `untar`, `ungz`, `unxz`, `unbz2`.

Then `after.kaem` concatenates `bootstrap.cfg` + `env` + `seed.kaem` and runs it:
`seed.kaem` builds `configurator` and `script-generator`, the latter reads the
arm64 `manifest` and emits `/steps/0.sh`, which finally runs
`steps/tcc-0.9.26/pass1.kaem`.

The arm64 `manifest` builds `checksum-transcriber-1.0`, `simple-patch-1.0`, and
`tcc-0.9.26` only. tcc-0.9.27 is a later milestone and is intentionally omitted.

### First-run checksums

`target_arm64/bootstrap.cfg` sets `UPDATE_CHECKSUMS=True` for the first
bootstrap, so the `configurator` / `script-generator` / tcc checksums are
*generated* (`*.arm64.checksums`) rather than verified. Once the build is
reproducible, capture and commit those checksum files and flip `UPDATE_CHECKSUMS`
back to `False`.

## The seed pipeline

The seed tools are arm64 (native on aarch64 hardware); only the file-name
conventions differ from amd64:

```
tcc.c --(tcc_cc -a arm64)--> .sl --(stack_c_arm64)--> .M1 --(blood-elf --64)--> .blood_elf
                                                          \--(M1)--> .macro --(hex2)--> tcc_s
```

- `tcc_cc -a arm64` emits arch-neutral 64-bit Stack-C (the `-a` flag only
  toggles 64-bit; the same `.sl` would serve amd64).
- `stack_c_arm64` translates Stack-C to aarch64 M1 assembly.
- `M1` + `hex2` assemble it into a static ELF, using
  `M2libc/aarch64/ELF-aarch64-debug.hex2` for the ELF header.

## What was added

- **`src/stack_c_intro_arm64.M1`** — self-contained arm64 runtime prologue.
  Register model: `x18` = operand stack pointer (`str x,[x18,-8]!` / `ldr
  x,[x18],8`), `x17` = locals base (BP, `[x17]` holds the frame return address),
  `x0` = top-of-stack accumulator, `x1` = second operand, `x16` = call target.
  Provides `_start` (brk-based bump allocator for the locals stack, argc/argv
  setup, `exit`), plus the `sys_syscall` and `sys_malloc` runtime functions, and
  every instruction-macro the backend emits. All hex is uppercase (this repo's
  `hex2` only accepts uppercase A–F).
- **`src/stack_c_arm64.c`** — Stack-C → aarch64 backend, ported emit-site by
  emit-site from `stack_c_amd64.c` (parsing/scoping logic is shared and
  unchanged). Conventions:
  - Calls: `blr x16`; the callee prologue stores `x30` to `[x17]`; `return`
    reloads `x30` from `[x17]` and `ret`. `()` adjusts the BP (`x17`) by
    `8*pos` around the call.
  - Immediates and addresses load via a PC-relative literal:
    `ldr w,#8 ; b #8 ; <4-byte literal>` (zero-extended).
  - Jumps load `&label` into `w16` and `br x16`; conditional jumps are an
    inverted fixed-offset skip (`b.<inv> #20`) over that load+br block.
  - Comparisons use `cmp` + `cset w0,<cond>`.
- **`src/arm64-asm.c`** + the `arm64-asm-{defs,include}` and
  `arm64-va-builtin-loop` simple-patches — applied **in-chroot** by the
  chroot-built `simple-patch` (see Milestone 2). The amd64 path never patches on
  the host; arm64 now matches that.
- **`src/sys_syscall.h`** — an aarch64 syscall-number block (write=64, read=63,
  close=57, exit=93, …) selected by `TCC_TARGET_ARM64`. Inert for the existing
  x86/amd64 builds. Note: the file-related calls that x86 exposes as
  `open`/`access`/`mkdir`/… only exist as `*at` variants on aarch64; the numbers
  are the `*at` syscalls, so those wrappers needed adapting (Milestone 2).

## Verification approach

Every aarch64 instruction encoding was checked against `llvm-mc --triple=aarch64
--show-encoding`. The chain was validated incrementally with small programs
(exit codes and stdout) before compiling `tcc.c`: nested function calls with
arguments, arithmetic, `for` loops, `if/else`, comparisons, string output via
`write`, and variadic `printf`. On an x86_64 dev host these ran under
`qemu-aarch64-static`; on aarch64 hardware they run natively.

```
$ tcc_s -version          # native, or: qemu-aarch64-static tcc_s -version
tcc version 0.9.26 (AArch64 Linux)

$ ./hello
Hello, World!
Variadic: answer = 42
```

## Milestone 2 — arm64 libc.a

`pass1.kaem` extracts the `mes-0.27.1-aarch64` tarball (which carries the aarch64
libc sources/headers) and drives the seed `tcc_s` to build `crt1.o`, `libc.a`,
`libtcc1.a`, and `libgetopt.a`, then compiles+links a static `hello.c`.

### The central blocker: tcc 0.9.26 has no arm64 assembler

`arm64_FILES` is only `arm64-gen.c arm64-link.c` — there is no `arm64-asm.c`, and
`arm64-gen.c` never `#define`s `CONFIG_TCC_ASM`, so any `asm()` is
`tcc_error("inline asm() not supported")`. Every mes libc arch primitive
(`_start`, `__sys_call*`, `setjmp`) is inline asm, so none could be compiled.

- **`src/arm64-asm.c`** — a minimal data-directive-only assembler (defines
  `CONFIG_TCC_ASM`; the generic `.int`/`.word`/label directives come from
  `tccasm.c`, and the instruction-level hooks are stubs that error). Wired in via
  the `arm64-asm-{defs,include}` simple-patches, applied in-chroot. This lets the
  primitives be written as raw aarch64 instruction words: `__asm__(".int 0x..")`,
  exactly like mes' existing 32-bit arm `__TINYC__` path.

### libc pieces added (in the `mes/` submodule, shipped via the distfile)

- `lib/linux/aarch64-mes-gcc/{crt1,crti,crtn,_exit,syscall,_write}.c` — runtime
  primitives as raw words. The Linux/aarch64 syscall ABI is number in `x8`, args
  `x0..x5`, `svc #0`, result `x0`; `crt1.c` reads argc/argv/envp off the entry
  stack (at `x29+224`, given tcc's `stp x29,x30,[sp,#-224]!` prologue).
- `lib/aarch64-mes-gcc/setjmp.c` — `setjmp`/`longjmp` (best-effort, like the arm
  `__TINYC__` path; only needs to *compile* for Milestone 2).
- `include/linux/aarch64/{syscall,kernel-stat,signal}.h` — asm-generic syscall
  numbers and `struct stat` (identical to riscv64). The `*at`-only file syscalls
  are reached through mes' existing `#elif defined(SYS_*at)` fallbacks.
- `include/stdint.h` / `include/setjmp.h` — LP64 `LONG_MAX`/`SIZE_MAX` and the
  `__aarch64__` `__jmp_buf` layout.

### stdarg / va_list (the subtle part)

`arm64-gen.c` already implements the AAPCS64 va mechanism via the native
`__va_start`/`__va_arg` builtins, so no `va_list.c` is needed (unlike the x86_64
port). But tcc's native `__va_arg` takes the **address** of its operand
(`gen_va_arg` does `gaddrof`), which only works when the operand is the va_list
storage itself. mes forwards a va_list across functions (`printf` → `vprintf` →
`vfprintf`); since `va_list` is an array (`va_list[1]`, per AAPCS64), the callee
receives a *pointer*, and `__va_arg` then reads the address of that pointer —
fetching garbage. So `include/stdarg.h` keeps the native `__va_start` (only ever
applied to a true local array) but routes `va_arg` through small C helpers
(`lib/aarch64-mes-gcc/va.c`) that take the decayed `__va_list *`, which is
uniform whether the va_list is local or forwarded. `pass1.kaem` appends
`aarch64-mes-gcc/va.c` to the unified libc for arm64.

### A latent seed-compiler bug

`tcc_cc` (the limited seed compiler) miscompiles tcc's `parse_builtin_params`
loop — `while ((c = *args++)) { switch (c) { …; continue; } }` — on its *second*
iteration, mis-dispatching any 2-argument builtin (e.g. `__va_start`) to the
`internal error` default. The x86_64 bootstrap never hit this (it uses a `char*`
va_list, not the arm64 builtins). The `arm64-va-builtin-loop` simple-patch
rewrites the loop as an indexed `for` + `if`/`else`, which `tcc_cc` compiles
correctly.

### Soft-float

The arm64 backend emits libcalls (`__extenddftf2`, `__addtf3`, …) for
`long double` (binary128). tcc ships these in `lib/lib-arm64.c`; `pass1.kaem`
compiles it into `libtcc1.a` for arm64 (the existing riscv64 libtcc1 branch was
widened to also fire for arm64, via a `LINK_LIBARM64` flag — the arm64 analogue
of libgcc's TFmode helpers).

## Milestone 3 — boot0/1/2 + fixpoint

`pass1.kaem` drives the same boot loop as amd64. The seed `tcc_s` compiles
`tcc.c` into `tcc-boot0`; each stage then rebuilds the full libc set (`crt1.o`,
`libc.a`, `libtcc1.a`, `libgetopt.a`) with the freshly built compiler and
compiles the next stage. Success is the same criterion as amd64: `tcc-boot2` and
`tcc-boot3` are byte-identical.

```
...
tcc version 0.9.26 (AArch64 Linux)      # tcc-boot0 -version
tcc version 0.9.26 (AArch64 Linux)      # tcc-boot1 -version
tcc version 0.9.26 (AArch64 Linux)      # tcc-boot2 -version
Hello, World!                           # hello rebuilt by tcc-boot2
Variadic: answer = 42
```

`tcc-boot1`, `tcc-boot2`, `tcc-boot3` are byte-identical (1109132 bytes);
`tcc-boot0` differs only because it is the lone stage built by the seed pipeline.

### aarch64 `setjmp`/`longjmp` and the caller's frame

`tcc_compile` wraps its body in `if (setjmp(s1->error_jmp_buf) == 0)`, so the
boot loop is the first runtime exercise of the mes `setjmp`/`longjmp`. Since tcc
0.9.26 has no arm64 assembler these are raw aarch64 instruction words, and they
have to cooperate with the prologue/epilogue tcc generates around them.

The subtlety is that a hand-written `setjmp` must **not** return through a bare
`ret`. tcc's prologue pushes the caller's `x29`/`x30` and repoints the frame
pointer `x29` at `setjmp`'s own frame; a bare `ret` would leave `sp`/`x29`
pointing there, and the caller would then read its locals (e.g. `tcc_compile`'s
`TCCState *`) off the wrong frame. So `setjmp` saves the *caller's* frame — fp
from `[x29]`, lr from `x30`, sp from `x29 + frame_size` — and returns `0` via a
normal C `return`, letting tcc emit its real epilogue to restore the caller;
`longjmp` reloads those saved slots and `ret`s straight into setjmp's caller.
(The one tcc-chosen constant, the frame size, is verified by re-disassembling the
compiled `setjmp`.)
