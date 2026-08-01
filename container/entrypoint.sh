#!/bin/sh
# Evidence for the musl unwind gap. Bind-mounted, so editing needs no rebuild.
#
# What this proves, without running a debugger at all: on 32-bit ARM and on
# aarch64 no FDE covers __cp_begin, the syscall stub every blocking call passes
# through. On x86_64 one does. Debug information is present in all cases - what
# is missing is unwind information, which -g does not provide.
set -u

ARCH=$(apk --print-arch 2>/dev/null || uname -m)
BIN=./sleeper-$ARCH   # per architecture: container/ is shared by all platforms
CC_FLAGS="-g -O2 -fno-inline -funwind-tables -pthread"
SYMS="__syscall_cp_asm __cp_begin __cp_end __syscall_cp_c nanosleep poll"

line() { printf "  %s\n" "----------------------------------------------------------"; }

printf '\n============================================================\n'
printf ' musl unwind gap - %s\n' "$(apk --print-arch)"
printf '============================================================\n\n'

printf 'environment\n'
printf '  %-14s %s\n' "arch" "$(apk --print-arch) / $(uname -m)"
printf '  %-14s %s\n' "musl" "$( (ldd --version 2>&1 || true) | sed -n 2p)"
printf '  %-14s %s\n' "gdb" "$(gdb --version | head -1 | sed 's/GNU gdb //')"
printf '  %-14s %s\n' "gcc" "$(gcc --version | head -1)"
apk info -e musl-dbg >/dev/null 2>&1 \
	&& printf '  %-14s %s\n' "musl-dbg" "installed" \
	|| printf '  %-14s %s\n' "musl-dbg" "MISSING - results below are meaningless"
printf '\n'

########################################################################
make -s BIN="$BIN" CFLAGS="$CC_FLAGS" >/dev/null || exit 1
UNWIND_SECTIONS=$(readelf -S "$BIN" | grep -Eio 'ARM\.exidx|eh_frame' | sort -u | tr '\n' ' ')
printf 'the test program itself\n'
printf '  %-14s %s\n' "unwind info" "${UNWIND_SECTIONS:-NONE}"
printf '  %-14s %s\n' "built with" "$CC_FLAGS"
printf '\n'

########################################################################
DBG=""
for CAND in /usr/lib/debug/lib/ld-musl-*.so.1.debug /usr/lib/debug/usr/lib/libc.musl-*.so.1.debug; do
	[ -f "$CAND" ] && DBG="$CAND"
done
if [ -z "$DBG" ]; then
	printf 'musl debug file not found - install musl-dbg\n\n'
	exit 1
fi

RANGES=$(readelf --debug-dump=frames "$DBG" 2>/dev/null \
         | grep -o 'pc=[0-9a-f]*\.\.[0-9a-f]*' | sed 's/^pc=//')

printf 'musl unwind coverage\n'
printf '  debug file   %s\n' "$DBG"
printf '  FDEs         %s\n' "$(echo "$RANGES" | grep -c .)"
printf '\n'
printf '  %-18s %-14s %s\n' "symbol" "address" "FDE"
line

MISSING_COUNT=0
TOTAL_COUNT=0
for SYM in $SYMS; do
	ADDR=$(readelf -sW "$DBG" | awk -v s="$SYM" '$8==s {print $2; exit}')
	[ -z "$ADDR" ] && continue
	TOTAL_COUNT=$((TOTAL_COUNT + 1))
	WANTED=$((0x$ADDR))
	HIT=""
	for RANGE in $RANGES; do
		LO=${RANGE%%..*}
		HI=${RANGE##*..}
		if [ "$((0x$LO))" -le "$WANTED" ] && [ "$WANTED" -lt "$((0x$HI))" ]; then
			HIT="ok"
			break
		fi
	done
	if [ -z "$HIT" ]; then
		HIT="MISSING"
		MISSING_COUNT=$((MISSING_COUNT + 1))
	fi
	printf '  %-18s 0x%-12s %s\n' "$SYM" "$ADDR" "$HIT"
done
line
printf '\n'

if [ "$MISSING_COUNT" -eq 0 ]; then
	printf 'VERDICT  every symbol on the cancellable-syscall path is covered.\n'
	printf '         This architecture is not affected.\n'
else
	printf 'VERDICT  %d of %d symbols on the cancellable-syscall path have no FDE.\n' \
		"$MISSING_COUNT" "$TOTAL_COUNT"
	printf '         Every blocking call - poll, nanosleep, pthread_cond_timedwait -\n'
	printf '         passes through them, so no sleeping thread can be unwound.\n'
fi
printf '\n'

########################################################################
# A live backtrace needs ptrace. Under qemu-user there is none, and the core
# dumps qemu writes carry no library mapping gdb can use - both failures would
# look like the reported bug without being it, so they are not shown.
printf 'live backtrace\n'

# How gdb reaches the process differs per platform, so it is generated here and
# sourced by both command files - which stay identical apart from the unwinder.
case "$(apk --print-arch)" in
	armhf|armv7) QEMU=/usr/bin/qemu-arm-static ;;
	aarch64)     QEMU=/usr/bin/qemu-aarch64-static ;;
	riscv64)     QEMU=/usr/bin/qemu-riscv64-static ;;
	ppc64le)     QEMU=/usr/bin/qemu-ppc64le-static ;;
	s390x)       QEMU=/usr/bin/qemu-s390x-static ;;
	loongarch64) QEMU=/usr/bin/qemu-loongarch64-static ;;
	*)           QEMU="" ;;   # x86_64 and x86 run natively, ptrace works
esac

run_pass() {
	CMDFILE="$1"
	LOG="/work/gdb-$2.txt"

	if [ -n "$QEMU" ] && [ -x "$QEMU" ]; then
		# qemu-user has no ptrace, so its own gdb server is the only way in.
		# The program starts at the entry point, hence break parked/continue.
		"$QEMU" -g 1234 "$BIN" >/dev/null 2>&1 &
		TARGET_PID=$!
		# Emulation is slow and varies by target; 2 s was not enough for
		# loongarch64, where the program had not parked yet and the backtrace
		# below showed startup frames instead.
		sleep 5
		printf 'target remote :1234\nbreak parked\ncontinue\ndelete breakpoints\n' \
			> /tmp/connect.gdb
	else
		# Native: ptrace works, and the program has already parked itself.
		"$BIN" >/dev/null 2>&1 &
		TARGET_PID=$!
		sleep 2
		printf 'attach %s\n' "$TARGET_PID" > /tmp/connect.gdb
	fi

	# Everything gdb says goes to the log, including errors - filtering here
	# once hid a failed connection behind an empty section. The hard bound
	# keeps a wedged pass from stopping the whole report.
	timeout 120 gdb -q -batch -nx -x "$CMDFILE" "$BIN" >"$LOG" 2>&1
	RC=$?

	kill "$TARGET_PID" 2>/dev/null
	wait "$TARGET_PID" 2>/dev/null

	[ "$RC" -eq 124 ] && printf 'gdb did not finish within 120 s\n' >> "$LOG"
	# Without this the section below looks like a backtrace of the parked
	# threads when it is really one of program startup - a reader would draw
	# the wrong conclusion from it.
	grep -q 'hit Breakpoint' "$LOG" || printf \
		'NOTE: the breakpoint was never hit, so the frames above are startup\n      frames, not sleeping threads - nothing about the unwind gap can be\n      concluded from them. Run without a debugger and the program does\n      park its threads, so this is the emulated gdb server not honouring\n      the breakpoint, not a property of musl. The FDE coverage above is\n      read from the ELF files and is unaffected.\n' >> "$LOG"
	[ "$RC" -ne 0 ] && [ "$RC" -ne 124 ] && printf 'gdb exited with %s\n' "$RC" >> "$LOG"
	cat "$LOG"
}

printf '\n  --- without gdb_musl_unwinder.py ---\n'
run_pass gdb_plain_command_file plain | sed 's/^/  /'
printf '\n  --- with gdb_musl_unwinder.py (one line different) ---\n'
run_pass gdb_unwinder_command_file unwinder | sed 's/^/  /'
printf '\n'
