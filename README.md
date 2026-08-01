# A clean backtrace is not possible with musl on ARM

If a thread is sleeping — waiting in `poll`, `nanosleep` or
`pthread_cond_timedwait` — a debugger cannot show where it came from. The
backtrace ends after one or two frames inside libc:

```
#0  __cp_end () at src/thread/arm/syscall_cp.s:25
#1  __syscall_cp_c (...) at src/thread/pthread_cancel.c:33
#2  0x00000000 in ?? ()
Backtrace stopped: previous frame identical to this frame (corrupt stack?)
```

Every blocking call goes through this code, so every sleeping thread is
affected, in every program. On x86_64 the same test prints the whole chain.

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

There is none for `arm` or `aarch64`. So `ADD_CFI=no`, the assembly is used
unannotated, and no `.s` file carries `.cfi_*` directives by hand.

This is unchanged in musl 1.2.6, the current release — which is what the
measurement below was taken against.

This is not a distribution problem. No build flag can add information that the
source does not contain.

## What was measured

Same musl version (1.2.6, the current release), same compiler, four architectures. The question is
whether the unwind tables describe each function on the blocking-call path:

| function           | x86_64 | armhf | armv7 | aarch64 |
|--------------------|--------|-------|-------|---------|
| `__syscall_cp_asm` | yes    | no    | no    | no      |
| `__cp_begin`       | yes    | no    | no    | no      |
| `__cp_end`         | yes    | no    | no    | no      |
| `__syscall_cp_c`   | yes    | yes   | yes   | yes     |
| `nanosleep`        | yes    | yes   | yes   | yes     |
| `poll`             | yes    | yes   | yes   | yes     |

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
#11 __clone () at src/thread/arm/clone.s:23
#12 __clone () at src/thread/arm/clone.s:23
#13 __clone () at src/thread/arm/clone.s:23
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
