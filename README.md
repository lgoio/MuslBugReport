# musl ships no unwind tables for its assembly, except on x86

`__syscall_cp_asm` and `__clone` are written in assembly, and unwind information
for assembly only exists if somebody puts it there. musl generates it with
`tools/add-cfi.$ARCH.awk`, and that file exists for `i386` and `x86_64`. On the
other sixteen architectures no FDE covers either function.

Every blocking call — `poll`, `nanosleep`, `pthread_cond_timedwait` — goes
through `__syscall_cp_asm`, so this is the frame every sleeping thread is
parked in.

What that costs depends on whether the debugger's fallback guess happens to be
right. On 32-bit ARM it is not, and the application part of the stack is simply
gone:

```
#0  __cp_end () at src/thread/arm/syscall_cp.s:25
#1  0x4085ebb0 in __syscall_cp_c (...) at src/thread/pthread_cancel.c:33
#2  0x00000000 in ?? ()
Backtrace stopped: previous frame identical to this frame (corrupt stack?)
```

That is measured on armhf and armv7. On aarch64, riscv64, ppc64le and s390x the
same gdb recovers the chain today, because those stubs have no prologue and its
fallback — CFA = `sp`, return address in the link register — is accidentally
correct. Nothing guarantees that: it is a guess that currently pays off, and
`eu-stack` on the same armv7 binary reports `no matching address range`.

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
| `loongarch64` | loongarch64 | **missing** | from source | [`tools/add-cfi.loongarch64.awk`](patch/tools/add-cfi.loongarch64.awk) |
| `m68k` | — | **missing** | from source | not written |
| `microblaze` | — | **missing** | from source | not written |
| `mips` | — | **missing** | from source | not written |
| `mips64` | — | **missing** | from source | not written |
| `mipsn32` | — | **missing** | from source | not written |
| `or1k` | — | **missing** | from source | not written |
| `powerpc` | — | **missing** | from source | not written |
| `powerpc64` | ppc64le | **missing** | measured | [`tools/add-cfi.powerpc64.awk`](patch/tools/add-cfi.powerpc64.awk) |
| `riscv32` | — | **missing** | from source | not written |
| `riscv64` | riscv64 | **missing** | measured | [`tools/add-cfi.riscv64.awk`](patch/tools/add-cfi.riscv64.awk) |
| `s390x` | s390x | **missing** | measured | [`tools/add-cfi.s390x.awk`](patch/tools/add-cfi.s390x.awk) |
| `sh` | — | **missing** | from source | not written |
| `x32` | — | **missing** | from source | not written |
| `x86_64` | x86_64 | covered | measured | — (musl's own) |

*measured* means read out of the ELF files Alpine ships for that architecture;
*from source* means the musl tree has the same two assembly files with no
`.cfi_*` in them and no generator. Alpine does not package the rest, so they
could not be measured here.

Full detail: [`results/architectures.txt`](results/architectures.txt).

## What was measured

Same musl version, same compiler. The question is whether the unwind tables
describe each function on the blocking-call path:

| function           | x86_64 | armhf | armv7 | aarch64 | riscv64 | ppc64le | s390x |
|--------------------|--------|-------|-------|---------|---------|---------|-------|
| `__syscall_cp_asm` | yes    | no    | no    | no      | no      | no      | no    |
| `__cp_begin`       | yes    | no    | no    | no      | no      | no      | no    |
| `__cp_end`         | yes    | no    | no    | no      | no      | no      | no    |
| `__clone`          | yes    | no    | no    | no      | no      | no      | no    |
| `__syscall_cp_c`   | yes    | yes   | yes   | yes     | yes     | yes     | yes   |
| `nanosleep`        | yes    | yes   | yes   | yes     | yes     | yes     | yes   |
| `poll`             | yes    | yes   | yes   | yes     | yes     | yes     | yes   |

The last three are C. The compiler wrote their tables itself — which is exactly
why only the assembly is missing.

Debug symbols are installed and loaded in all cases — gdb even prints file and
line for `__cp_begin`. Only the unwind tables are missing, and `-g` does not
produce those.

Full output per architecture:

- [`results/report-x86_64.txt`](results/report-x86_64.txt) — reference, everything works
- [`results/report-armhf.txt`](results/report-armhf.txt)
- [`results/report-armv7.txt`](results/report-armv7.txt)
- [`results/report-aarch64.txt`](results/report-aarch64.txt)

## The same problem at the other end

`clone.s` is unannotated too. It sits at the bottom of every thread stack, so
even a backtrace that gets that far cannot stop properly — gdb repeats the last
frame until it hits a limit:

```
#11 __clone () at src/thread/arm/clone.s:24
#12 __clone () at src/thread/arm/clone.s:24
#13 __clone () at src/thread/arm/clone.s:24
...
```

## Proof that this is the only cause

`container/gdb_musl_unwinder.py` is a small gdb add-on that supplies the one
missing frame and nothing else. It reads no debug information. With it loaded,
the whole chain appears:

```
#4  __pthread_cond_timedwait (...) at src/thread/pthread_cond_timedwait.c:100
#5  park_in_cond () at sleeper.c:60
#6  level_three () at sleeper.c:74
#7  level_two () at sleeper.c:81
#8  level_one () at sleeper.c:86
#9  worker () at sleeper.c:91
#10 start () at src/thread/pthread_create.c:207
```

Everything above the stub unwinds normally, because everything above it does
have unwind tables. One missing frame is all that stands in the way.

## A fix

[`patch/`](patch/) writes the missing generators — six of them, one for every
affected architecture Alpine builds:

| architecture | Alpine | generator | sleeping threads | `__clone` stops repeating |
|---|---|---|---|---|
| `arm` | armhf, armv7 | yes | **fixed** | yes |
| `aarch64` | aarch64 | yes | tables added | yes |
| `loongarch64` | loongarch64 | yes | tables added | yes |
| `riscv64` | riscv64 | yes | tables added | not needed |
| `powerpc64` | ppc64le | yes | tables added | not needed |
| `s390x` | s390x | yes | tables added | not needed |
| the other ten | not packaged | not written | — | — |

**No source file is edited.** The generators are new files; `configure` finds
them and turns `ADD_CFI` on by itself. A build without `-g` is unaffected —
`ADD_CFI` stays off and the assembly goes through unannotated, exactly as today.
`.text` comes out byte-identical to a stock build.

*fixed* is reserved for where the symptom was measured and went away: 32-bit
ARM. Elsewhere the tables were missing and are now present, which removes the
reliance on a lucky guess — the visible backtrace was already correct there.

The last column is about `clone.s`. musl zeroes the frame pointer in the child
half on arm, aarch64 and loongarch64, and the generators turn that into CFI, so
`__clone` stops repeating. The other three carry no such marker and need none:
`__clone` already appears once per thread there.

Details and how to verify: [`patch/README.md`](patch/README.md).

## Running it

Debian or Ubuntu with Docker. Everything else is checked and offered:

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

=== result
    completed: x86_64 armhf armv7 aarch64

    Each report contains two gdb passes over the same process:
      run 1  plain gdb
      run 2  same gdb plus gdb_musl_unwinder.py

    Expected picture:
      x86_64   both passes show the full call chain - no gap to begin with
      armhf    run 1 truncated, run 2 complete
      armv7    run 1 truncated, run 2 complete
      aarch64  run 1 truncated, run 2 complete

    Attach the report-*.txt files. The contrast is the argument:
    same source, same Alpine version, same packages - only the
    architecture differs.
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
results/                    output
```

## Note on the reproducer

Under `qemu-user` a debugger cannot attach — `ptrace` is not implemented there
(`warning: ptrace: Function not implemented`). The reproducer therefore uses
qemu's own gdb server, which is why the images carry a static qemu. The table
above does not depend on any of this. On real hardware plain gdb works and none
of it is needed.
