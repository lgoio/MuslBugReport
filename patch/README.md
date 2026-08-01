# A patch

[`cfi-arm-aarch64.diff`](cfi-arm-aarch64.diff) adds `.cfi_*` directives to the
four assembly files that carry the gap, against musl 1.2.6:

```
src/thread/arm/syscall_cp.s
src/thread/arm/clone.s
src/thread/aarch64/syscall_cp.s
src/thread/aarch64/clone.s
```

## Not the same thing as the gdb add-on

[`../container/gdb_musl_unwinder.py`](../container/gdb_musl_unwinder.py) exists
to prove where the gap is. It is not a fix, and it cannot become one:

- It works **inside gdb only**. `eu-stack`, `libunwind`, `perf`, and any program
  that unwinds itself in a crash handler see nothing of it.
- It hard-codes one frame layout per architecture, read off the disassembly. Any
  change to the stub silently invalidates it.
- Somebody has to know it exists and load it.

The patch puts the information in the library, where every consumer finds it —
including the ones that cannot load a Python script. The two are not
alternatives; the add-on is a diagnostic, the patch is the repair.

## The generator variant, tried and measured

musl generates these directives on i386 and x86_64 instead of writing them out,
so the obvious question is whether arm should do the same. Rather than argue
about it, [`tools/add-cfi.arm.awk`](tools/add-cfi.arm.awk) and
[`tools/add-cfi.aarch64.awk`](tools/add-cfi.aarch64.awk) are here, written after
`add-cfi.x86_64.awk`. Dropped into an otherwise untouched 1.2.6 tree, `configure`
finds them and turns `ADD_CFI` on by itself.

Both architectures build, and every sleeping thread unwinds to its entry point —
the generator does the job. Full output:
[`../results/patch-generators.txt`](../results/patch-generators.txt).

It cannot finish `clone.s`. Ending a thread stack means marking the return
address undefined in the child path, and nothing in the assembly says which path
that is: it is knowledge about what the function *means*, not about what it
does. On arm `__clone` therefore still repeats until the backtrace limit; on
aarch64 it stops, but with `corrupt stack?` rather than cleanly.

So the two are not alternatives — `clone.s` needs that one directive either way:

| | generator | written out |
|---|---|---|
| sleeping threads unwind | yes | yes |
| `__clone` repetition ends | no | yes |
| files touched | 13 per architecture | 4 |
| new files | 2 | 0 |
| `_init` in `crti.s` | FDE covers the prologue only | untouched |

The last row is a side effect of turning `ADD_CFI` on for everything: `_init` is
assembled from several objects, so a per-file generator only ever sees its
prologue. x86 does not hit this because its `crti.s` carries no `.type`
directive, and the generator only starts a frame at labels that have one.

## What it does

Each file gets `.cfi_sections .debug_frame`, the same choice musl already makes
in `tools/add-cfi.x86_64.awk` — *"don't put CFI data in the .eh_frame ELF
section (which we don't keep)"*. Nothing lands in `.eh_frame`.

**`syscall_cp.s`** — 32-bit ARM pushes four registers and returns through `lr`,
so the frame needs `.cfi_adjust_cfa_offset 16` and one `.cfi_rel_offset` per
saved register. `__cp_end` pops them again while `__cp_cancel` is branched to
with the registers still saved, so the pop is bracketed by
`.cfi_remember_state` / `.cfi_restore_state`. aarch64 has no prologue at all:
`.cfi_startproc` and `.cfi_endproc` are enough, because the default rules
(CFA = `sp`, return address in `x30`) already describe it.

**`clone.s`** — the same treatment for the parent path, plus `.cfi_undefined`
for the return-address register in the child. That is the marker for the
outermost frame, and it is what stops a backtrace from repeating `__clone`
until it hits a limit.

## Verifying it

```sh
./patch/verify.sh              # stage 1, about a minute per architecture
./patch/verify.sh --full       # also builds musl and takes a real backtrace
```

Needs the images from [`../run-on-host.sh`](../run-on-host.sh).

**Stage 1** assembles the two affected files before and after the patch and asks
whether an FDE covers each symbol. It reads the objects directly, so it needs no
debugger and no ARM hardware.

**Stage 2** builds all of musl from the patched source, links the reproducer's
`sleeper.c` against it statically and takes a backtrace with **plain gdb** — no
Python unwinder, no gdb add-on. The static link matters: the binary carries the
patched musl itself, so neither a loader path nor an installed `musl-dbg`
package can affect the result. It also prints `ADD_CFI` from `config.mak`, which
stays `no` — the coverage comes from the patch, not from musl's own generator.

Output per architecture: [`../results/patch-armhf.txt`](../results/patch-armhf.txt),
[`patch-armv7.txt`](../results/patch-armv7.txt),
[`patch-aarch64.txt`](../results/patch-aarch64.txt).
