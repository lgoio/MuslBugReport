# musl ships no unwind tables for its assembly, except on x86

`__syscall_cp_asm` and `__clone` are written in assembly, and unwind information
for assembly only exists if somebody puts it there. musl generates it with
`tools/add-cfi.$ARCH.awk`, and that file exists for `i386` and `x86_64`. On the
other sixteen architectures no FDE covers either function.

Every blocking call — `poll`, `nanosleep`, `pthread_cond_timedwait` — goes
through `__syscall_cp_asm`, so this is the frame every sleeping thread is
parked in.

What that costs differs by architecture. On 32-bit ARM the application part of
the stack is simply gone:

```
#0  __cp_end () at src/thread/arm/syscall_cp.s:25
#1  0x4085ebb0 in __syscall_cp_c (...) at src/thread/pthread_cancel.c:33
#2  0x00000000 in ?? ()
Backtrace stopped: previous frame identical to this frame (corrupt stack?)
```

That is measured on armhf and armv7. On aarch64, riscv64, ppc64le and s390x the
same gdb recovers the chain today — those stubs save nothing on the stack, and
gdb copes. The tables are absent there all the same, and `eu-stack` on the
armv7 binary reports `no matching address range` either way.

## Why

musl adds the needed information to its hand-written assembly automatically,
but only on x86. From `configure`:

```sh
test -f "$srcdir/tools/add-cfi.$ARCH.awk" && ... && ADD_CFI=yes
```

The source tree contains two of those files:

```
tools/add-cfi.i386.awk
tools/add-cfi.x86_64.awk
```

There is none for any other architecture. So `ADD_CFI=no` there, the assembly
is used unannotated, and no `.s` file carries `.cfi_*` directives by hand.

That is still true in musl 1.2.6, the current release, which is what the
measurement below was taken against. It is not a distribution problem either:
no build flag can add information the source does not contain.

## Which architectures

Every architecture writes this code in assembly, and unwind information for
assembly only exists if somebody puts it there. musl generates it with
`tools/add-cfi.$ARCH.awk` — and that file exists for two of the eighteen
architectures that have the code.

| musl arch | Alpine | unwind info today | how established | generator here |
|---|---|---|---|---|
| `aarch64` | aarch64 | **missing** | measured | [`tools/add-cfi.aarch64.awk`](patch/tools/add-cfi.aarch64.awk) |
| `arm` | armhf, armv7 | **missing** | measured | [`tools/add-cfi.arm.awk`](patch/tools/add-cfi.arm.awk) |
| `i386` | x86 | covered | from source | — (musl's own) |
| `loongarch64` | loongarch64 | **missing** | measured | [`tools/add-cfi.loongarch64.awk`](patch/tools/add-cfi.loongarch64.awk) |
| `m68k` | — | **missing** | from source | not written |
| `microblaze` | — | **missing** | from source | not written |
| `mips` | — | **missing** | from source | not written |
| `mips64` | — | **missing** | from source | not written |
| `mipsn32` | — | **missing** | from source | not written |
| `or1k` | — | **missing** | from source | not written |
| `powerpc` | — | **missing** | from source | not written |
| `powerpc64` | ppc64le | **missing** | measured | [`tools/add-cfi.powerpc64.awk`](patch/tools/add-cfi.powerpc64.awk) |
| `riscv32` | — | **missing** | assembled | [`tools/add-cfi.riscv32.awk`](patch/tools/add-cfi.riscv32.awk) |
| `riscv64` | riscv64 | **missing** | measured | [`tools/add-cfi.riscv64.awk`](patch/tools/add-cfi.riscv64.awk) |
| `s390x` | s390x | **missing** | measured | [`tools/add-cfi.s390x.awk`](patch/tools/add-cfi.s390x.awk) |
| `sh` | — | **missing** | from source | not written |
| `x32` | — | **missing** | from source | not written |
| `x86_64` | x86_64 | covered | measured | — (musl's own) |

*measured* means read out of the ELF files Alpine ships for that architecture.
*assembled* means Alpine ships none, so the two files were assembled here and
the coverage read out of the objects. *from source* means only that the tree
has the same two assembly files with no `.cfi_*` in them and no generator.

Full detail: [`results/architectures.txt`](results/architectures.txt).

## What was measured

Same musl version, same compiler. The question is whether the unwind tables
describe each function on the blocking-call path:

| function | x86_64 | armhf | armv7 | aarch64 | riscv64 | ppc64le | s390x | loong64 |
|---|---|---|---|---|---|---|---|---|
| `__syscall_cp_asm` | yes | no | no | no | no | no | no | no |
| `__cp_begin` | yes | no | no | no | no | no | no | no |
| `__cp_end` | yes | no | no | no | no | no | no | no |
| `__clone` | yes | no | no | no | no | no | no | no |
| `__syscall_cp_c` | yes | yes | yes | yes | yes | yes | yes | yes |
| `nanosleep` | yes | yes | yes | yes | yes | yes | yes | yes |
| `poll` | yes | yes | yes | yes | yes | yes | yes | yes |

The last three are C. The compiler wrote their tables itself — which is exactly
why only the assembly is missing.

Debug symbols are installed and loaded in all cases — gdb even prints file and
line for `__cp_begin`. Only the unwind tables are missing, and `-g` does not
produce those.

Full output per architecture:

- [`report-x86_64.txt`](results/report-x86_64.txt) — reference, nothing missing
- [`report-armhf.txt`](results/report-armhf.txt) — the gap is visible here
- [`report-armv7.txt`](results/report-armv7.txt) — and here
- [`report-aarch64.txt`](results/report-aarch64.txt)
- [`report-riscv64.txt`](results/report-riscv64.txt)
- [`report-ppc64le.txt`](results/report-ppc64le.txt)
- [`report-s390x.txt`](results/report-s390x.txt)
- [`report-loongarch64.txt`](results/report-loongarch64.txt) — tables only, see the note in it

## The same problem at the other end

`clone.s` is unannotated too, and it sits at the bottom of every thread stack.
On 32-bit ARM, once the syscall frame is described, the backtrace reaches
`__clone` and then cannot stop — gdb repeats the last frame until it hits a
limit:

```
#11 __clone () at src/thread/arm/clone.s:24
#12 __clone () at src/thread/arm/clone.s:24
#13 __clone () at src/thread/arm/clone.s:24
...
```

On the other architectures measured here `__clone` appears once per thread
today, so the missing table costs nothing visible at that end. It is still
missing.

## Workaround for existing systems

On an existing system — no patch, no rebuild —
[`container/gdb_musl_unwinder.py`](container/gdb_musl_unwinder.py) supplies the
one frame the stub does not describe, from inside gdb, on **ARMv7, ARMv6/ARMhf
and aarch64/ARM64**. It reads no debug information; the layout comes from the
disassembly.

```sh
wget https://raw.githubusercontent.com/lgoio/MuslBugReport/refs/heads/main/container/gdb_musl_unwinder.py
```

```
(gdb) attach PID                    # or target remote, or open a core
(gdb) source gdb_musl_unwinder.py   # after attaching, not before: it
                                    # resolves __cp_begin at load time
(gdb) set backtrace limit 30        # __clone repeats without it
(gdb) thread apply all -c bt        # -c, or it stops at the first bad thread
(gdb) musl-unwinder-status          # how often it applied, and why not
```

The two comments matter. Sourced before the process is there, the symbols it
needs do not exist yet — it falls back to guessing from a register on 32-bit ARM
and declines entirely on aarch64. And without `-c`, `thread apply all` aborts
at the first thread it cannot walk, which is usually the first one.

On 32-bit ARM, where the frames are otherwise lost, the whole chain comes back:

```
#4  __pthread_cond_timedwait (...) at src/thread/pthread_cond_timedwait.c:100
#5  park_in_cond () at sleeper.c:60
#6  level_three () at sleeper.c:74
#7  level_two () at sleeper.c:81
#8  level_one () at sleeper.c:86
#9  worker () at sleeper.c:91
#10 start () at src/thread/pthread_create.c:207
```

Everything above the stub unwinds normally, because everything above it has
unwind tables. That single frame is the whole difference.

Its limits are why the real fix belongs in the library: only gdb sees it, so
`eu-stack`, `libunwind`, `perf` and any program that unwinds itself in a crash
handler do not; it hard-codes one frame layout per architecture; and somebody
has to know it exists and load it.

## A fix

[`patch/`](patch/) writes the missing generators — seven of them: one for
every affected architecture Alpine builds, plus riscv32:

| architecture | Alpine | generator | sleeping threads | `__clone` stops repeating |
|---|---|---|---|---|
| `arm` | armhf, armv7 | yes | **fixed** | yes |
| `aarch64` | aarch64 | yes | tables added | yes |
| `loongarch64` | loongarch64 | yes | tables added | yes |
| `riscv64` | riscv64 | yes | tables added | not needed |
| `powerpc64` | ppc64le | yes | tables added | not needed |
| `s390x` | s390x | yes | tables added | not needed |
| `riscv32` | not packaged | yes | tables added ‡ | not needed |
| the other ten | not packaged | not written | — | — |

**No source file is edited.** The generators are new files; `configure` finds
them and turns `ADD_CFI` on by itself. A build without `-g` is unaffected —
`ADD_CFI` stays off and the assembly goes through unannotated, exactly as today.
`.text` comes out byte-identical to a stock build.

*fixed* is reserved for where the symptom was measured and went away: 32-bit
ARM. Elsewhere the tables were missing and are now present; the visible
backtrace was already correct there.

The last column is about `clone.s`. musl zeroes the frame pointer in the child
half on arm, aarch64 and loongarch64, and the generators turn that into CFI, so
`__clone` stops repeating. The others carry no such marker and need none:
`__clone` already appears once per thread there.

‡ Alpine has no riscv32 image, so the two affected files were assembled in
the riscv64 container with `-march=rv32i -mabi=ilp32` and the coverage read
back, rather than building musl as a whole. In these files riscv32 differs
from riscv64 only in load and store widths.

Details and how to verify: [`patch/README.md`](patch/README.md).

## Running it

Debian or Ubuntu with Docker and qemu-user. Everything else is checked and
offered — the script installs what is missing, fetches the static qemu
binaries the images carry, and skips any architecture it cannot run:

```sh
./run-on-host.sh
```

This builds one image per architecture and writes the files under `results/`.
The table above needs no debugger and no ARM hardware — it is read straight
out of the ELF files.

You do not have to run it to see the outcome. This is what it prints:

```
=== host
    Ubuntu 26.04 LTS
    kernel 7.0.0-28-generic, arch x86_64

=== docker
    docker present: Docker version 29.6.0, build fb59821

=== emulation
    all platforms already run.

=== qemu binaries for the images
    loongarch64 minirootfs present.
    all present.

=== x86_64 (linux/amd64)
    building alpine-bugreport-x86_64
    running both gdb passes
    written to results/report-x86_64.txt

=== armhf (linux/arm/v6)
    building alpine-bugreport-armhf
    running both gdb passes
    written to results/report-armhf.txt

=== armv7 (linux/arm/v7)
    building alpine-bugreport-armv7
    running both gdb passes
    written to results/report-armv7.txt

=== aarch64 (linux/arm64)
    building alpine-bugreport-aarch64
    running both gdb passes
    written to results/report-aarch64.txt

=== riscv64 (linux/riscv64)
    building alpine-bugreport-riscv64
    running both gdb passes
    written to results/report-riscv64.txt

=== ppc64le (linux/ppc64le)
    building alpine-bugreport-ppc64le
    running both gdb passes
    written to results/report-ppc64le.txt

=== s390x (linux/s390x)
    building alpine-bugreport-s390x
    running both gdb passes
    written to results/report-s390x.txt

=== loongarch64 (linux/loong64)
    building alpine-bugreport-loongarch64
    running both gdb passes
    written to results/report-loongarch64.txt

=== result
    completed: x86_64 armhf armv7 aarch64 riscv64 ppc64le s390x loongarch64

    Each report contains two gdb passes over the same process:
      run 1  plain gdb
      run 2  same gdb plus gdb_musl_unwinder.py

    No FDE covers __syscall_cp_asm or __clone on any of these except
    x86_64. What that costs differs, and the reports show which:

      x86_64       covered by musl own generator - nothing missing
      armhf        run 1 loses the application frames, run 2 recovers
      armv7        them - this is where the gap is visible
      aarch64      no FDE either, but gdb copes with these stubs, so
      riscv64      run 1 already shows the chain. The tables are
      ppc64le      still missing.
      s390x
      loongarch64  FDE coverage only - the emulated gdb server ignores
                   the breakpoint, so no live backtrace is taken here
```

The files it names are the ones committed under
[`results/`](results/), so the two can be compared directly.

To look around by hand:

```sh
./up armv7      # also armhf, aarch64, x86_64; no argument = all
./sh armv7      # shell into the container
./down
```

## Files

```
run-on-host.sh              start here
docker/Dockerfile.<arch>    one image per architecture
container/sleeper.c         three threads parked through a 3-deep call chain
container/entrypoint.sh     produces the report
container/gdb_*_command_file   the two gdb runs, one line apart
container/gdb_musl_unwinder.py the add-on described above
patch/tools/                the six generators - the actual fix
patch/000N-*.patch          the same, as a per-architecture series
patch/verify.sh             checks them, two stages
results/                    output, one report per architecture
```

## Note on the reproducer

Under `qemu-user` a debugger cannot attach — `ptrace` is not implemented there
(`warning: ptrace: Function not implemented`). The reproducer therefore uses
qemu's own gdb server, which is why the images carry a static qemu. The table
above does not depend on any of this. On real hardware plain gdb works and none
of it is needed.
