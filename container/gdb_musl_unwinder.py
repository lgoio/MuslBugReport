# gdb unwinder for musl's __syscall_cp_asm on 32-bit ARM and on aarch64.
#
# PROBLEM
# Unwind information for hand-written assembly only exists if the author writes
# .cfi_* directives; a compiler cannot infer it. musl's syscall stub has none,
# and it does not need any: unlike glibc, musl implements pthread cancellation
# without stack unwinding, so nothing inside musl ever unwinds through that
# code. Only debuggers do.
#
# Every blocking call goes through that stub, so every sleeping thread is
# affected. gdb stops after one or two frames and the whole application part of
# the backtrace is lost.
#
# Measured against Alpine v3.24 (musl 1.2.6-r2), runtime library plus
# musl-dbg, asking whether any FDE covers __cp_begin:
#
#     x86_64    covered       - nothing to do
#     armhf     NOT covered   - handled here
#     armv7     NOT covered   - handled here
#     aarch64   NOT covered   - handled here
#
# x86_64 is fine because its stub keeps the return address on the stack, which
# the CIE default rule already describes. On ARM it lives in a register, which
# no default rule can express.
#
# FRAME LAYOUTS (both read from the disassembly, not from documentation)
#
# 32-bit ARM (Thumb) - saves four registers, returns through lr:
#     __syscall_cp_asm: mov     r12, sp
#                       push    {r4, r5, r6, r7}      16 bytes
#     __cp_begin:       ldr     r0, [r0] ; cmp ; bne __cp_cancel
#                       mov     r7, r1                clobbers r7 (frame ptr)
#                       ldmia.w r12, {r2,r3,r4,r5,r6} clobbers r4-r6
#                       svc     #0                    <- threads park here
#     __cp_end:         pop     {r4, r5, r6, r7} ; bx lr
#
#     => CFA = sp + 16   caller pc = lr   r4..r7 from [sp+0..12]
#
# aarch64 - no prologue at all, __syscall_cp_asm and __cp_begin share an
# address, and the stub returns straight through x30:
#     __cp_begin:       ldr w0,[x0] ; cbnz w0,__cp_cancel
#                       mov x8, x1 ; mov x0, x2 ; ... ; mov x5, x7
#                       svc     #0                    <- threads park here
#     __cp_end:         ret
#
#     => CFA = sp (unchanged)   caller pc = x30   nothing to restore
#
# DETECTION
# Primarily by address: pc inside [__cp_begin, __cp_end). Those are static
# symbols inside musl, so plain &__cp_begin does not resolve from the
# application context; taking the address explicitly does. Requires musl-dbg.
#
# On 32-bit ARM there is a fallback that needs no symbols at all: r12 holds the
# stack pointer from before the push and survives the syscall, because Linux
# preserves every register except r0. aarch64 has no such marker, so there it
# is the address range or nothing.
#
# USAGE
#     (gdb) attach PID                    # or target remote, or open a core
#     (gdb) source gdb_musl_unwinder.py
#     (gdb) set backtrace limit 30
#     (gdb) thread apply all -c bt
#     (gdb) musl-unwinder-status
#
# Source it AFTER the process is there. The __cp_begin/__cp_end addresses are
# resolved at load time, and musl is not mapped before that; sourced too early
# it falls back to guessing from a register on 32-bit ARM and declines on
# aarch64, without anything looking like an error.
#
# The backtrace limit is not optional. Once this supplies the missing frame the
# walk reaches __clone, which has no unwind information either and no marker
# for the end of a thread stack, so gdb keeps producing the same frame at full
# CPU until something stops it.
#
# The -c ("continue on error") matters too: without it "thread apply all" aborts
# at the first failing thread, which is usually the first one.

import re
import struct

import gdb
from gdb.unwinder import Unwinder


# Registers clobbered by the stub are passed through anyway, otherwise gdb
# reports "Register N was not saved" while evaluating function arguments. Their
# values then come from the syscall rather than from the caller, which is
# irrelevant for the call chain but can mislead when arguments are printed.
PASS_CLOBBERED = True

# Report per hit which registers could not be set.
VERBOSE = False


class _FrameId(object):
    __slots__ = ("sp", "pc")

    def __init__(self, sp, pc):
        self.sp = sp
        self.pc = pc


def _symbol_address(name):
    """Address of a static symbol, or None.

    __cp_begin and __cp_end are static, so they are not visible from the
    application context - taking their address explicitly is what works.
    gdb.lookup_minimal_symbol does not exist in every gdb (16.3 does not have
    it), and a bare hasattr check is not enough, so both routes are tried.

    MUST NOT be called from inside an unwinder callback: evaluating an
    expression re-enters gdb from within its own frame machinery, which hangs
    the session. _CpRange resolves ahead of time and the callback only reads
    the cached result.
    """
    try:
        return int(gdb.parse_and_eval("(unsigned long)&%s" % name))
    except Exception:
        pass
    try:
        text = gdb.execute("info address %s" % name, to_string=True)
        match = re.search(r"0x[0-9a-fA-F]+", text)
        if match:
            return int(match.group(0), 16)
    except Exception:
        pass
    return None


class _CpRange(object):
    """[__cp_begin, __cp_end), resolved outside the unwinder callback.

    Resolution is attempted when this file is sourced and again whenever an
    objfile appears, because musl is usually not loaded yet at source time -
    the command file connects to the process afterwards.
    """

    lo = None
    hi = None

    @classmethod
    def resolve(cls, event=None):
        if cls.lo is not None:
            return
        lo = _symbol_address("__cp_begin")
        hi = _symbol_address("__cp_end")
        if lo is not None and hi is not None and hi > lo:
            cls.lo, cls.hi = lo, hi

    @classmethod
    def get(cls):
        # Cache only. Resolving here would deadlock, see _symbol_address.
        return cls.lo, cls.hi


for _event in ("new_objfile", "stop"):
    try:
        getattr(gdb.events, _event).connect(_CpRange.resolve)
    except Exception:
        pass


class MuslSyscallCp(Unwinder):
    hits = 0
    skips = {}

    def __init__(self):
        super(MuslSyscallCp, self).__init__("musl-syscall-cp")

    @classmethod
    def _skip(cls, reason):
        cls.skips[reason] = cls.skips.get(reason, 0) + 1
        return None

    def __call__(self, pending_frame):
        # An unwinder must never let an exception escape - that would break
        # every backtrace in an unattended run.
        try:
            return self._unwind(pending_frame)
        except Exception as exc:
            MuslSyscallCp._skip("exception: %s" % exc)
            return None

    # -- helpers ---------------------------------------------------------
    @staticmethod
    def _arch(pending_frame):
        for getter in (
            lambda: pending_frame.architecture().name(),
            lambda: gdb.selected_inferior().architecture().name(),
            lambda: gdb.selected_frame().architecture().name(),
        ):
            try:
                name = getter()
                if name:
                    return name
            except Exception:
                continue
        return None

    @staticmethod
    def _read(pending_frame, *names):
        """First readable of the given register names."""
        for name in names:
            try:
                return pending_frame.read_register(name)
            except Exception:
                continue
        return None

    @staticmethod
    def _in_stub(pc_int):
        lo, hi = _CpRange.get()
        if lo is None:
            return None            # cannot tell
        # __cp_end is included, hence <= and not <. Where the pc lands after a
        # blocking syscall depends on who reports it: a Linux kernel names the
        # svc instruction itself, so it can restart it, while qemu's gdb server
        # reports the following instruction - which is __cp_end. At that point
        # the pop has not run yet, so the frame layout is still the one below.
        return lo <= pc_int <= hi

    # -- the two layouts -------------------------------------------------
    def _unwind(self, pending_frame):
        arch = self._arch(pending_frame)
        if arch is None:
            return MuslSyscallCp._skip("architecture undetectable")
        if arch.startswith("aarch64"):
            return self._unwind_arm64(pending_frame)
        if arch.startswith("arm"):
            return self._unwind_arm32(pending_frame)
        return MuslSyscallCp._skip("%s: musl covers __cp_begin, nothing to do" % arch)

    def _unwind_arm32(self, pending_frame):
        sp = self._read(pending_frame, "sp")
        pc = self._read(pending_frame, "pc")
        lr = self._read(pending_frame, "lr")
        r12 = self._read(pending_frame, "r12", "ip")
        if sp is None or pc is None or lr is None:
            return MuslSyscallCp._skip("arm32: registers unreadable")

        sp_i = int(sp) & 0xFFFFFFFF
        lr_i = int(lr) & 0xFFFFFFFF
        pc_i = int(pc) & 0xFFFFFFFF

        inside = self._in_stub(pc_i)
        if inside is False:
            return MuslSyscallCp._skip("arm32: pc outside __cp_begin..__cp_end")
        if inside is None:
            # No musl symbols. r12 still identifies the frame: it holds the
            # stack pointer from before the push and survives the syscall.
            if r12 is None or (int(r12) & 0xFFFFFFFF) != (sp_i + 16):
                return MuslSyscallCp._skip("arm32: no symbols and r12 != sp+16")
        if lr_i == 0:
            return MuslSyscallCp._skip("arm32: lr == 0")

        try:
            saved = struct.unpack(
                "<4I", gdb.selected_inferior().read_memory(sp_i, 16).tobytes())
        except Exception:
            return MuslSyscallCp._skip("arm32: stack unreadable")

        cfa = sp_i + 16
        word = sp.type

        def mk(value):
            return gdb.Value(value & 0xFFFFFFFF).cast(word)

        info = pending_frame.create_unwind_info(_FrameId(mk(cfa), pc))
        failed = []

        def put(name, value):
            try:
                info.add_saved_register(name, value)
            except Exception as exc:
                failed.append("%s(%s)" % (name, exc))

        for index, name in enumerate(("r4", "r5", "r6", "r7")):
            put(name, mk(saved[index]))
        put("sp", mk(cfa))
        put("pc", mk(lr_i & ~1))

        # Untouched by the stub, but the API treats anything not mentioned as
        # "not saved" and stops there. cpsr also carries the Thumb bit.
        keep = ["cpsr", "r8", "r9", "r10", "r11", "lr"]
        if PASS_CLOBBERED:
            keep += ["r0", "r1", "r2", "r3", "r12"]
        for name in keep:
            value = self._read(pending_frame, name)
            if value is not None:
                put(name, value)

        MuslSyscallCp.hits += 1
        if VERBOSE and failed:
            gdb.write("[musl-unwinder] could not set: %s\n" % ", ".join(failed))
        return info

    def _unwind_arm64(self, pending_frame):
        sp = self._read(pending_frame, "sp")
        pc = self._read(pending_frame, "pc")
        lr = self._read(pending_frame, "lr", "x30")
        if sp is None or pc is None or lr is None:
            return MuslSyscallCp._skip("arm64: registers unreadable")

        pc_i = int(pc) & 0xFFFFFFFFFFFFFFFF
        lr_i = int(lr) & 0xFFFFFFFFFFFFFFFF
        sp_i = int(sp) & 0xFFFFFFFFFFFFFFFF

        # aarch64 has no register that marks the frame the way r12 does on
        # 32-bit ARM, so the address range is the only usable test.
        inside = self._in_stub(pc_i)
        if inside is None:
            return MuslSyscallCp._skip(
                "arm64: __cp_begin/__cp_end not resolvable - install musl-dbg")
        if not inside:
            return MuslSyscallCp._skip("arm64: pc outside __cp_begin..__cp_end")
        if lr_i == 0:
            return MuslSyscallCp._skip("arm64: lr == 0")

        # The stub allocates no frame and saves nothing: CFA is sp itself.
        word = sp.type

        def mk(value):
            return gdb.Value(value & 0xFFFFFFFFFFFFFFFF).cast(word)

        info = pending_frame.create_unwind_info(_FrameId(mk(sp_i), pc))
        failed = []

        def put(name, value):
            try:
                info.add_saved_register(name, value)
            except Exception as exc:
                failed.append("%s(%s)" % (name, exc))

        put("sp", mk(sp_i))
        put("pc", mk(lr_i))

        # x19-x28 are callee-saved and x29 is the frame pointer; the stub uses
        # neither, so they pass through unchanged. x0-x8 are clobbered by it.
        keep = ["cpsr", "pstate", "lr", "x29"]
        keep += ["x%d" % n for n in range(19, 29)]
        if PASS_CLOBBERED:
            keep += ["x%d" % n for n in range(0, 9)]
        for name in keep:
            value = self._read(pending_frame, name)
            if value is not None:
                put(name, value)

        MuslSyscallCp.hits += 1
        if VERBOSE and failed:
            gdb.write("[musl-unwinder] could not set: %s\n" % ", ".join(failed))
        return info


class MuslUnwinderStatus(gdb.Command):
    """Report how often the musl unwinder applied or declined, and why."""

    def __init__(self):
        super(MuslUnwinderStatus, self).__init__(
            "musl-unwinder-status", gdb.COMMAND_STATUS)

    def invoke(self, arg, from_tty):
        _CpRange.resolve()
        lo, hi = _CpRange.get()
        if lo is None:
            gdb.write("__cp_begin/__cp_end: not resolvable (musl-dbg missing?)\n")
        else:
            gdb.write("__cp_begin..__cp_end: 0x%x..0x%x\n" % (lo, hi))
        gdb.write("musl-syscall-cp: applied %d times\n" % MuslSyscallCp.hits)
        if MuslSyscallCp.skips:
            for reason, count in sorted(MuslSyscallCp.skips.items()):
                gdb.write("  declined (%s): %d\n" % (reason, count))
        else:
            gdb.write("  declined: 0\n")


MuslUnwinderStatus()
gdb.unwinder.register_unwinder(None, MuslSyscallCp(), replace=True)
_CpRange.resolve()
try:
    gdb.invalidate_cached_frames()
except Exception:
    pass
print("Loaded unwinder: musl-syscall-cp (arm32 + aarch64; thread apply all -c bt)")
