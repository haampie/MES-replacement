/* Libc functions GNU make needs that mes libc 0.9.26 does not provide.
   Compiled by the seed tcc and linked into make.  aarch64 Linux.

   - ftruncate(2): a raw syscall (mes has no inline asm and tcc 0.9.26 has no
     aarch64 assembler, so we go through mes's _sys_call2 wrapper).
     __NR_ftruncate == 46 in the asm-generic ABI aarch64 uses.
   - tmpfile(3): mes has open/fdopen/mktemp/unlink but no tmpfile, so we
     synthesise the usual "create, fdopen, immediately unlink" idiom. */

#include <stdio.h>
#include <stdlib.h>          /* malloc, free */
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <sys/stat.h>        /* S_IFIFO */
#include <dirent.h>          /* DIR, struct dirent */
#include <linux/syscall.h>   /* _sys_callN */

#ifndef __NR_ftruncate
#define __NR_ftruncate 46
#endif
#ifndef SYS_mknodat
#define SYS_mknodat 33
#endif
#ifndef SYS_getdents64
#define SYS_getdents64 61
#endif
#ifndef SYS_openat
#define SYS_openat 56
#endif
#ifndef AT_FDCWD
#define AT_FDCWD (-100)
#endif
/* Correct aarch64/asm-generic O_DIRECTORY.  mes fcntl.h also carries the
   x86_64 value (0x10000), which is O_DIRECT on aarch64 -- and that wrong
   value is what got baked into mes libc.a's opendir, making the kernel
   reject opendir() with EINVAL.  See the opendir override below. */
#define MES_O_DIRECTORY 0x4000

int
ftruncate (int fd, long length)
{
  return (int) _sys_call2 (__NR_ftruncate, (long) fd, length);
}

/* mkfifo(3) via the mknodat(2) syscall (aarch64 has no bare mknod syscall).
   Enables make's fifo-style jobserver. */
int
mkfifo (const char *path, mode_t mode)
{
  return (int) _sys_call4 (SYS_mknodat, (long) AT_FDCWD, (long) path,
                           (long) (mode | S_IFIFO), 0L);
}

/* Directory reading.  mes libc.a's opendir passes the wrong O_DIRECTORY bit
   on aarch64 (see MES_O_DIRECTORY above) so every opendir() fails with EINVAL;
   GNU make's file_exists_p()/dir cache then finds nothing, e.g. it cannot
   locate "Makefile" by itself.  Override the trio here with a correct
   getdents64-based implementation.  These object-file definitions take
   precedence over the libc.a archive members at link time.

   The kernel's struct linux_dirent64 (what getdents64 returns) has the same
   layout as mes's struct dirent on aarch64 -- d_ino(8) d_off(8) d_reclen(2)
   d_type(1) d_name[] -- so we can hand back kernel records directly. */

#ifndef DIRBUF_SIZE
#define DIRBUF_SIZE 4096
#endif

DIR *
mes_opendir (const char *name)
{
  DIR *d;
  int fd = (int) _sys_call3 (SYS_openat, (long) AT_FDCWD, (long) name,
                             (long) (O_RDONLY | MES_O_DIRECTORY));
  if (fd < 0)
    return 0;

  d = (DIR *) malloc (sizeof *d);
  if (d == 0)
    {
      close (fd);
      return 0;
    }
  d->fd = fd;
  d->allocation = DIRBUF_SIZE;
  d->data = (char *) malloc (d->allocation);
  if (d->data == 0)
    {
      free (d);
      close (fd);
      return 0;
    }
  d->size = 0;
  d->offset = 0;
  d->filepos = 0;
  return d;
}

struct dirent *
mes_readdir (DIR *d)
{
  struct dirent *e;

  if (d->offset >= d->size)
    {
      long n = _sys_call3 (SYS_getdents64, (long) d->fd,
                           (long) d->data, (long) d->allocation);
      if (n <= 0)
        return 0;           /* end of directory or error */
      d->size = (size_t) n;
      d->offset = 0;
    }

  e = (struct dirent *) (d->data + d->offset);
  d->offset += e->d_reclen;
  return e;
}

int
mes_closedir (DIR *d)
{
  int fd;
  if (d == 0)
    return -1;
  fd = d->fd;
  free (d->data);
  free (d);
  return close (fd);
}

FILE *
tmpfile (void)
{
  char name[] = "/tmp/makeXXXXXX";
  int fd;
  FILE *f;

  if (mktemp (name) == 0 || name[0] == '\0')
    return 0;

  fd = open (name, O_RDWR | O_CREAT | O_EXCL, 0600);
  if (fd < 0)
    return 0;

  /* Unlink now; the open fd keeps the file alive until fclose. */
  unlink (name);

  f = fdopen (fd, "wb+");
  if (f == 0)
    {
      close (fd);
      return 0;
    }
  return f;
}
