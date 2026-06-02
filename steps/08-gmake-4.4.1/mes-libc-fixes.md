# What to fix in mes libc (aarch64) — found while building GNU make 4.4.1

These are the mes-libc deficiencies that the seed tcc 0.9.26 + mes libc hit when
building GNU make 4.4.1 on aarch64. Each was worked around in
`mes-compat.{c,h}`, but the right place to fix them is **mes libc itself**. They
are ordered by severity. Header paths below are as they appear in the chroot
(`rootfs/usr/include/mes/…`), which mirror mes's own `include/…` tree.

All numeric values below are the **aarch64 / asm-generic ABI** values
(`<asm-generic/fcntl.h>`, `<asm-generic/errno.h>`, etc.), which is the ABI
aarch64 uses.

---

## 1. CRITICAL — `opendir` uses the wrong `O_DIRECTORY` on aarch64

**Symptom:** every `opendir()` fails with `EINVAL`. Any code that lists a
directory finds nothing. For GNU make this meant it could not locate its own
`Makefile` (make's `file_exists_p()` is `readdir`-based), so an ordinary
`make` in a directory with a `Makefile` printed *"No targets specified and no
makefile found"* even though `stat("Makefile")` succeeds.

**Root cause:** mes's `opendir` issues
`openat(AT_FDCWD, name, O_RDONLY | O_DIRECTORY)` with `O_DIRECTORY == 0x10000`.
`0x10000` is the **x86_64** value of `O_DIRECTORY`; on aarch64/asm-generic that
bit is **`O_DIRECT`**, which the kernel rejects with `EINVAL` for a normal
directory open.

The smoking gun is in `include/fcntl.h`: it defines `O_DIRECTORY` **twice**, in
two different `#if` branches —

```
#define O_DIRECTORY   0x4000     /* correct: asm-generic / aarch64 */
...
#define O_DIRECTORY   0x10000    /* x86_64 value — wrong for aarch64 */
```

— and the branch active when libc was compiled picked `0x10000`.

**Fix:** ensure the asm-generic/aarch64 branch of `include/fcntl.h` is the one
selected for aarch64, with the correct values:

| flag         | aarch64 / asm-generic | (x86_64, for contrast) |
|--------------|-----------------------|------------------------|
| `O_DIRECTORY`| `0x4000`  (`040000`)  | `0x10000`              |
| `O_DIRECT`   | `0x10000` (`0200000`) | `0x4000`               |
| `O_NOFOLLOW` | `0x8000`  (`0100000`) | `0x20000`              |

Then rebuild libc so `opendir.c` picks up `O_DIRECTORY = 0x4000`. (mes's
`readdir` itself is fine — it uses `getdents64`, syscall 61, and the
`struct dirent` layout already matches the kernel's `linux_dirent64` on
aarch64: `d_ino`(8) `d_off`(8) `d_reclen`(2) `d_type`(1) `d_name[]`.)

---

## 2. HIGH — `assert` does not honor `NDEBUG`

**Symptom:** code that does `#ifndef NDEBUG … variable used only by assert …`
fails to compile with *"X undeclared"* once `NDEBUG` is defined, because mes
keeps `assert()` live and it still references the now-undeclared variable.
(GNU make defines `NDEBUG` in `makeint.h`; it broke on `implicit.c:655 'dend'`.)

**Root cause:** `include/assert.h` always defines the active form:

```c
#define assert(x) ((x) ? (void)0 : __assert_fail (#x, 0, 0, 0))
```

ignoring `NDEBUG`. The C standard requires `<assert.h>` to make `assert` a
no-op when `NDEBUG` is defined, and to be **re-includable** (re-evaluating
`NDEBUG` on each include).

**Fix:** make `include/assert.h` standard-conforming:

```c
#undef assert
#ifdef NDEBUG
# define assert(e) ((void)0)
#else
# define assert(e) ((e) ? (void)0 : __assert_fail (#e, __FILE__, __LINE__, 0))
void __assert_fail (const char *, const char *, unsigned, const char *);
#endif
```

and drop the `#ifndef __MES_ASSERT_H` one-shot guard around the macro part so a
second `#include <assert.h>` after `#define NDEBUG` re-takes effect (the
prototype can stay guarded).

---

## 3. MEDIUM — POSIX declarations gated behind `BOOTSTRAP_WITH_POSIX`

**Symptom:** without `-DBOOTSTRAP_WITH_POSIX`, `_POSIX_VERSION` and `getcwd`
(among others) are not declared, so make's `makeint.h` falls into a legacy
branch and emits `char *getcwd (void);`, which clashes with mes's real
`char *getcwd(char*, size_t)` → *"incompatible types for redefinition of
'getcwd'"*.

**Root cause:** in `include/unistd.h` (and peers) the POSIX block is
`#if defined (BOOTSTRAP_WITH_POSIX)`. Consumers that don't define it see a
non-POSIX libc.

**Fix:** either declare the standard POSIX functions (`getcwd`, etc.) and
`_POSIX_VERSION` unconditionally, or default `BOOTSTRAP_WITH_POSIX` to on for
the non-`SYSTEM_LIBC` build. At minimum, `_POSIX_VERSION` should be exposed so
portable code takes the POSIX path.

---

## 4. MEDIUM — missing macros / structs

Add to the appropriate aarch64 headers (asm-generic values):

**`include/fcntl.h`:**
```c
#define O_CLOEXEC   02000000   /* 0x80000 */
#define O_NONBLOCK     04000   /* 0x800   */
/* record locking */
#define F_GETLK   5
#define F_SETLK   6
#define F_SETLKW  7
#define F_RDLCK   0
#define F_WRLCK   1
#define F_UNLCK   2
struct flock {
  short l_type;
  short l_whence;
  off_t l_start;
  off_t l_len;
  pid_t l_pid;
};
```

**`include/errno.h`:** `#define ENOTSUP 95` (== `EOPNOTSUPP` on Linux).

**`include/dirent.h`:** the `d_type` constants
```c
#define DT_UNKNOWN 0  #define DT_FIFO 1  #define DT_CHR 2  #define DT_DIR 4
#define DT_BLK 6      #define DT_REG 8   #define DT_LNK 10 #define DT_SOCK 12
#define DT_WHT 14
```
(mes already stores `d_type` in `struct dirent`; it just doesn't name the
values.)

---

## 5. MEDIUM — missing libc functions

Implement in mes libc (aarch64 syscalls in parentheses):

- **`ftruncate(int, off_t)`** — `__NR_ftruncate == 46`. (mes has no `ftruncate`
  at all.)
- **`mkfifo(const char *, mode_t)`** — `mknodat(AT_FDCWD, path, mode|S_IFIFO, 0)`
  via `__NR_mknodat == 33` (aarch64 has no bare `mknod` syscall). **Without
  `mkfifo`, GNU make's fifo jobserver cannot be enabled** (`configure` leaves
  `HAVE_MKFIFO` undef and `JOBSERVER_USE_FIFO` off).
- **`tmpfile(void)`** — synthesise from `mktemp`/`open(…,O_RDWR|O_CREAT|O_EXCL)`/
  immediate `unlink`/`fdopen`. (mes has the pieces but not `tmpfile`.)
- **`mktemp`** exists in `libc.a` but has **no prototype** in any mes header, so
  tcc defaults it to `int` and `*mktemp(p)` becomes a deref-of-int error. Add
  `char *mktemp(char *);` to `include/stdlib.h`.

See `mes-compat.c` for reference implementations of all four.

---

## 6. LOW — stdio is completely unbuffered

`printf`/`fputs`/etc. issue **one `write(2)` syscall per byte** (visible under
`strace`). Correct, but pathologically slow for anything chatty. Not a
correctness blocker; worth a buffered `FILE` layer eventually. Also: mes
`vfprintf` does **not** support `%p` (prints `vfprintf: not supported: %:p` and
then crashed a test program) — worth adding, since `%p` is common in debug code.

---

## Quick reproduction of the opendir bug (no make needed)

```c
#include <stdio.h>
#include <dirent.h>
int main(void){ DIR *d = opendir("."); printf(d?"ok\n":"NULL\n"); return !d; }
```
Compile with the seed tcc + mes libc and run under `strace`: you will see
`openat(AT_FDCWD, ".", O_RDONLY|O_DIRECT) = -1 EINVAL` and the program prints
`NULL`. After fix #1 it prints `ok`.
