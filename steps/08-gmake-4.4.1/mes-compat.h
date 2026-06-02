/* Macros/decls missing from mes libc, force-included when building GNU make
   with the seed tcc 0.9.26.  aarch64 Linux values. */
#ifndef MES_MAKE_COMPAT_H
#define MES_MAKE_COMPAT_H
/* mes headers hide their POSIX declarations (getcwd, _POSIX_VERSION, ...)
   unless this is defined.  Must be set before any mes header is included,
   which is why this file is force-included (-include) first. */
#ifndef BOOTSTRAP_WITH_POSIX
#define BOOTSTRAP_WITH_POSIX 1
#endif

/* mes <assert.h> ignores NDEBUG and always keeps assert() live.  GNU make
   defines NDEBUG (makeint.h) and relies on assert() vanishing, so variables
   used only inside assert()s sit under '#ifndef NDEBUG' and disappear while
   mes keeps the assert that references them -> "undeclared" errors
   (e.g. implicit.c 'dend').  Pre-empt mes's header (set its include guard)
   and provide the NDEBUG-honoring no-op assert make expects. */
#define __MES_ASSERT_H 1
#define assert(e) ((void)0)
#ifndef O_CLOEXEC
#define O_CLOEXEC 02000000
#endif
#ifndef O_NONBLOCK
#define O_NONBLOCK 04000   /* asm-generic value, missing from mes fcntl.h */
#endif

/* Enable make's fifo-style jobserver.  configure left HAVE_MKFIFO undefined
   because mes libc has no mkfifo symbol; we supply one (via mknodat) in
   mes-compat.c, so turn the feature on.  This is set before config.h is read
   (this header is force-included first); config.h leaves HAVE_MKFIFO only
   commented-out, so our definition stands. */
#ifndef HAVE_MKFIFO
#define HAVE_MKFIFO 1
#endif
/* fcntl record locking, absent from mes fcntl.h (asm-generic values).
   Used by make's output-sync (osync_acquire in posixos.c). */
#ifndef F_RDLCK
#define F_RDLCK 0
#define F_WRLCK 1
#define F_UNLCK 2
#endif
#ifndef F_SETLK
#define F_GETLK  5
#define F_SETLK  6
#define F_SETLKW 7
#endif
#ifndef MES_HAVE_STRUCT_FLOCK
#define MES_HAVE_STRUCT_FLOCK 1
struct flock {
  short l_type;
  short l_whence;
  long  l_start;   /* off_t */
  long  l_len;     /* off_t */
  int   l_pid;     /* pid_t */
};
#endif

/* errno values missing from mes errno.h (aarch64/asm-generic) */
#ifndef ENOTSUP
#define ENOTSUP 95
#endif
/* Functions present in mes libc.a but with no prototype in mes headers,
   so tcc defaults them to int and dereferences/casts go wrong. */
char *mktemp (char *template);

/* Functions absent from mes libc entirely; implemented in mes-compat.c and
   linked into make.  tmpfile() MUST be prototyped before use: without it tcc
   assumes an int return and truncates the FILE* to 32 bits.  Pull in <stdio.h>
   here (force-included first) so FILE is defined for the prototype. */
#include <stdio.h>
#include <sys/stat.h>   /* mode_t, S_IFIFO, mknod */
FILE *tmpfile (void);
int   ftruncate (int fd, long length);
int   mkfifo (const char *path, mode_t mode);

/* mes libc.a's opendir passes the x86_64 O_DIRECTORY bit, which is O_DIRECT
   on aarch64, so opendir() always fails with EINVAL and make can't list any
   directory (it can't even find "Makefile" on its own).  We supply corrected
   versions under distinct names in mes-compat.c and redirect make's calls to
   them, so the broken libc symbols are never referenced (no link clash). */
#include <dirent.h>
DIR           *mes_opendir (const char *name);
struct dirent *mes_readdir (DIR *d);
int            mes_closedir (DIR *d);
#define opendir(n)  mes_opendir (n)
#define readdir(d)  mes_readdir (d)
#define closedir(d) mes_closedir (d)

/* d_type values missing from mes dirent.h */
#ifndef DT_UNKNOWN
#define DT_UNKNOWN 0
#define DT_FIFO 1
#define DT_CHR  2
#define DT_DIR  4
#define DT_BLK  6
#define DT_REG  8
#define DT_LNK  10
#define DT_SOCK 12
#define DT_WHT  14
#endif
#endif
