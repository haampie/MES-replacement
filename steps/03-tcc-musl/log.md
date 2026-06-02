# 03 — tcc-musl (tcc 0.9.26 rebuilt against musl libc)

We never build tcc 0.9.27. The chain uses **tcc 0.9.26 throughout**, built twice:

1. **seed** — tcc 0.9.26 on **mes libc** (`steps/tcc-0.9.26`, built in the kaem
   chroot). Materializes float constants but mis-rounds some decimals
   (`38.53`→`43.3`) because mes-libc's `strtod` is wrong.
2. **tcc-musl** — *this step*: the same tcc 0.9.26 source + arm64 patches
   (`steps/tcc-0.9.26/simple-patches` + `mes-aarch64/` overlay) recompiled and
   **self-hosted against musl 1.1.24** (`steps/musl-1.1.24`, the scaffold libc).
   musl's `strtod` is correct, so this compiler rounds FP literals properly.

Output: `tcc-musl-stage3`, the compiler that builds binutils (step 04) and
GCC stage 1 (step 05).

- **Build tree:** `bootstrap-tcc-musl/` — `tcc-src/`, `tcc-musl`,
  `tcc-musl-stage2`, `tcc-musl-stage3`, `build-havefloat.sh`,
  `build-havefloat.log`.
- **Self-hosting:** 3 stages (stage1 built by seed tcc; stage2 by stage1;
  stage3 by stage2). **stage2 == stage3** byte-for-byte → fixpoint reached.
- **Full forensic prose:** `steps/musl-1.1.24/log.md` (the gdb bisection of the
  seed-tcc `-4096UL` and array-`va_list` miscompiles, and the HAVE_FLOAT
  discovery, all live there).

## THE critical build flag: `-DHAVE_FLOAT=1`

In the bootstrappable 0.9.26 fork *all* FP handling is wrapped in
`#if HAVE_FLOAT` (upstream tinycc has no such macro). If the macro is undefined:

- `tccpp.c` parse_number: `#if HAVE_FLOAT tokc.d = strtod(...) #endif` — the
  literal's value is never computed.
- `tccgen.c` init_putv: `#if HAVE_FLOAT *(double*)ptr = vtop->c.d #endif` — the
  constant bytes are never written.

→ **every `float`/`double` literal becomes `0.0`** (even `1.0`). aarch64 codegen
is otherwise fine. Confirmed: `double x = 38.53;` emitted 8 zero bytes instead
of `a4 70 3d 0a d7 43 43 40`.

This single bug was the root cause of the **entire** GCC/musl `cc1` crash
taxonomy (because `cc1` is built by `tcc-musl-stage3`, every FP constant in
GCC's own source was zeroed):

- `real.c:1724 gcc_assert(digit <= 10)` ICE — real.c's internal `log10(2)` was 0.
- `double f(){return 1.0;}` crash at -O1+, `pow(x,2.0)` crash at -O0, the CCP
  segfault, double→long-double promotion, MPFR `dbl_int_bug`, GMP `2^63` probe —
  all the same zeroed-constant origin.

**Fix (pure build-flag, no source patch):** add `-DHAVE_FLOAT=1` to the
`tcc-musl` build line and rebuild stage1→stage3 (`build-havefloat.sh`). Verified:
`38.53` → correct 8 bytes; double→long `38.53`→38, `2.5`→2; the creduced
`real_to_decimal` repro prints `OK: 11` (stage3-without-HAVE_FLOAT ran away,
exit 124). Once on, **most `-O0`/`-fno-tree-ccp`/stub workarounds in the GCC and
musl logs become unnecessary** — only the genuine aarch64 CCP/TImode
`-fno-tree-ccp` flag remains.

See `project-tcc-fp-constant-bug` memory and `gcc-bootstrap-notes.md` for how
this insight collapsed the downstream patch count.
