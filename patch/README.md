# A fix

musl already knows how to do this. `configure` looks for
`tools/add-cfi.$ARCH.awk`, and where it finds one, every `.s` file goes through
it at build time and comes out annotated. That file exists for `i386` and
`x86_64`. For the other sixteen architectures it does not, which is the whole
bug — see [`../results/architectures.txt`](../results/architectures.txt).

So the fix is to write the missing ones. [`tools/`](tools/) has seven — every
affected architecture Alpine builds, and therefore every one this reproducer can
actually run, plus riscv32:

```
tools/add-cfi.arm.awk
tools/add-cfi.aarch64.awk
tools/add-cfi.riscv64.awk
tools/add-cfi.powerpc64.awk
tools/add-cfi.s390x.awk
tools/add-cfi.loongarch64.awk
tools/add-cfi.riscv32.awk
```

**No source file is edited.** Drop them into an untouched musl tree and
`configure` turns `ADD_CFI` on by itself. A build without `-g` is unaffected:
`ADD_CFI` stays off, the assembly goes through unannotated, exactly as today.

The generated code does not change either. `.cfi_*` directives emit a debug
section and no instructions, so `.text` comes out byte-identical to a stock
build — measured over the whole library, not argued from the definition.

## Not the same thing as the gdb add-on

[`../container/gdb_musl_unwinder.py`](../container/gdb_musl_unwinder.py) exists
to prove where the gap is. It is not a fix, and it cannot become one:

- It works **inside gdb only**. `eu-stack`, `libunwind`, `perf`, and any program
  that unwinds itself in a crash handler see nothing of it.
- It hard-codes one frame layout per architecture, read off the disassembly. Any
  change to the stub silently invalidates it.
- Somebody has to know it exists and load it.

The generators put the information in the library, where every consumer finds
it — including the ones that cannot load a Python script.

## What they do

Each is written after `add-cfi.x86_64.awk` and keeps its structure: a linear
pass that tracks what the stack pointer does, which registers still hold the
caller's values, and where a function begins and ends. Each starts with
`.cfi_sections .debug_frame`, the same choice musl already makes there —
*"don't put CFI data in the .eh_frame ELF section (which we don't keep)"*.

Two things are worth calling out.

**Branches, without flow analysis.** In `arm/syscall_cp.s`, `__cp_cancel` is
branched to with the registers still on the stack, while the instruction before
it has just popped them. A linear pass would carry the popped state into
`__cp_cancel` and describe that frame wrongly — which is worse than describing
nothing, because a debugger would then report confident nonsense. Bracketing the
pop with `.cfi_remember_state` / `.cfi_restore_state` and restoring at the
return fixes it without any analysis: a return ends a path, so whatever follows
inherits the state from before the pop.

**The end of a thread stack.** musl zeroes the frame pointer in the child half
of `clone.s` — `mov fp,#0` on arm, `mov x29,0` on aarch64, `move $fp,$zero` on
loongarch64 — so that frame-pointer unwinders stop there. The generators read
that as what it is and say the same thing in CFI, with `.cfi_undefined` for the
return-address register.

That matters on 32-bit ARM. Once the syscall frame is described, the backtrace
reaches `__clone` and, without the termination, repeats it until the backtrace
limit. On the architectures that carry no such marker — riscv64, powerpc64,
s390x — the generators emit no termination, and measurement says none is needed:
`__clone` appears exactly once per thread there today.

Clearing the return-address register instead, the way musl's `_start` does, does
not work here: all three call the thread function with a linking branch
(`jalr`, `basr`, `bctrl`), which sets that register again immediately.

## Verifying it

```sh
./patch/verify.sh              # stage 1, about a minute per architecture
./patch/verify.sh --full       # also builds musl and takes a real backtrace
```

Needs the images from [`../run-on-host.sh`](../run-on-host.sh).

**Stage 1** assembles the two affected files twice — once straight through the
compiler, which is what musl does today, and once through the generator first —
and asks whether an FDE covers each symbol. It reads the objects directly, so it
needs no debugger and no hardware of that architecture.

**Stage 2** drops the generator into an untouched musl tree, builds it, replaces
the container's libc and takes a backtrace with **plain gdb**. No Python
unwinder, no gdb add-on. It prints `ADD_CFI` from `config.mak` so the source of
the coverage is not in doubt.

Results: [`../results/`](../results/).

## Prior art

- [2020-07-05](https://www.openwall.com/lists/musl/2020/07/05/1) — Daniel Santos
  submits CFI for mipsel `__syscall_cp_asm`, with the same symptom: *"attaching a
  debugger to a program making such a syscall results in the debugger being
  completely unable to perform a backtrace"*. He wrote the directives into the
  assembly by hand. Rich Felker's reply to the CFI itself was *"this part looks
  ok"*; the patch was not merged because unrelated changes were bundled with it.
- [2024-03-13](https://www.openwall.com/lists/musl/2024/03/13/6) — incomplete gdb
  backtraces reported on aarch64 and armel. Szabolcs Nagy: musl has debug info
  for asm on x86 only, generated by `tools/add-cfi.*.awk`, and *"if you provide
  that for another target that will work too"*.

This is that.
