#!/bin/sh
# Checks patch/cfi-arm-aarch64.diff. Runs inside one of the reproducer
# containers; patch/verify.sh starts it from the host.
#
# Stage 1 assembles the two affected files before and after the patch and asks
# whether an FDE covers each symbol on the blocking-call path. That is the whole
# claim, and it needs neither a full build nor a debugger.
#
# Stage 2 (--full) builds all of musl with the patch, replaces the container's
# libc with it and takes a backtrace with plain gdb - no Python unwinder, no gdb
# add-on of any kind. That is what patching Alpine amounts to, and it is the
# answer to "does this actually fix the reported symptom". Slow under emulation.
set -u

MUSL=musl-1.2.6
URL=https://musl.libc.org/releases/$MUSL.tar.gz
PATCHFILE=/patch/cfi-arm-aarch64.diff
WORK=/tmp/verify
FULL=no
[ "${1:-}" = "--full" ] && FULL=yes

ARCH=$(apk --print-arch)
case "$ARCH" in
	armhf|armv7) ASMDIR=arm ;;
	aarch64)     ASMDIR=aarch64 ;;
	*)
		printf 'musl covers %s with tools/add-cfi.%s.awk already.\n' "$ARCH" "$ARCH"
		printf 'The patch changes nothing here, so there is nothing to verify.\n'
		exit 0 ;;
esac

line() { printf '  ----------------------------------------------------------\n'; }
SYMS="__syscall_cp_asm __cp_begin __cp_end __clone"

printf '=== patch verification - %s\n\n' "$ARCH"

# -- sources ---------------------------------------------------------------
rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK" || exit 1
if ! wget -q "$URL" -O "$MUSL.tar.gz"; then
	printf 'could not download %s\n' "$URL"
	exit 1
fi
tar -xzf "$MUSL.tar.gz" && cp -a "$MUSL" musl-patched
( cd musl-patched && patch -p1 --batch --silent < "$PATCHFILE" ) || {
	printf 'the patch does not apply to %s\n' "$MUSL"
	exit 1
}
printf 'sources\n'
printf '  musl         %s\n' "$MUSL"
printf '  patch        applies cleanly\n'
printf '  compiler     %s\n' "$(gcc --version | head -1)"
printf '\n'

# -- stage 1: does the patch produce the missing FDEs? ---------------------
# Assembled exactly the way musl's Makefile does it when ADD_CFI=no, which is
# the case on these architectures: straight through the compiler driver.
covered() {   # covered <object> <symbol>
	_ranges=$(readelf --debug-dump=frames "$1" 2>/dev/null \
	          | grep -o 'pc=[0-9a-f]*\.\.[0-9a-f]*' | sed 's/^pc=//')
	_addr=$(readelf -sW "$1" | awk -v s="$2" '$8==s {print $2; exit}')
	[ -z "$_addr" ] && return 1
	_want=$((0x$_addr))
	for _r in $_ranges; do
		_lo=${_r%%..*}; _hi=${_r##*..}
		[ "$((0x$_lo))" -le "$_want" ] && [ "$_want" -lt "$((0x$_hi))" ] && return 0
	done
	return 1
}

printf 'stage 1 - FDE coverage of the assembled objects\n\n'
printf '  %-18s %-10s %s\n' "symbol" "stock" "patched"
line
STAGE1_FAIL=0
for TREE in "$MUSL" musl-patched; do
	for SRC in syscall_cp clone; do
		gcc -c -g "$TREE/src/thread/$ASMDIR/$SRC.s" -o "$WORK/$TREE-$SRC.o" 2>/dev/null
	done
done
for SYM in $SYMS; do
	BEFORE=no; AFTER=no
	for SRC in syscall_cp clone; do
		covered "$WORK/$MUSL-$SRC.o" "$SYM" && BEFORE=yes
		covered "$WORK/musl-patched-$SRC.o" "$SYM" && AFTER=yes
	done
	printf '  %-18s %-10s %s\n' "$SYM" "$BEFORE" "$AFTER"
	[ "$AFTER" = no ] && STAGE1_FAIL=$((STAGE1_FAIL + 1))
done
line
printf '\n'
if [ "$STAGE1_FAIL" -eq 0 ]; then
	printf 'VERDICT  every symbol on the cancellable-syscall path now has an FDE.\n'
else
	printf 'VERDICT  %d symbols still have no FDE - the patch is incomplete.\n' "$STAGE1_FAIL"
fi
printf '\n'

[ "$FULL" = no ] && {
	printf '(stage 2 skipped - pass --full to build musl and take a real backtrace)\n'
	exit 0
}

# -- stage 2: a real backtrace against a patched musl ----------------------
printf 'stage 2 - backtrace against a musl built from the patched source\n\n'
apk add --no-cache make >/dev/null 2>&1

cd "$WORK/musl-patched" || exit 1
if ! ./configure --prefix="$WORK/inst" CFLAGS="-g -O2" \
		>"$WORK/configure.log" 2>&1; then
	tail -5 "$WORK/configure.log"; exit 1
fi
# Proof that the fix does not come from musl's own generator: it stays off.
printf '  %-14s %s\n' "ADD_CFI" "$(grep -E '^ADD_CFI' "$WORK/musl-patched/config.mak" \
	|| echo 'not set (no tools/add-cfi.'"$ASMDIR"'.awk, as expected)')"
if ! make -j"$(nproc)" install >"$WORK/build.log" 2>&1; then
	printf '  build failed:\n'; tail -20 "$WORK/build.log"; exit 1
fi
printf '  %-14s %s\n' "built" "$WORK/inst/lib/libc.so"

# Replace the container's musl with the patched one. This is what patching
# Alpine amounts to, and it keeps the reproducer's own sleeper and gdb
# machinery in play instead of some special-purpose binary.
#
# The rename is atomic on purpose: writing into the file in place would corrupt
# the mapping of every process already running against it. Processes started
# afterwards - the sleeper, gdb - pick up the new one.
#
# Safe because the patch adds no instructions: .cfi_* directives emit a debug
# section and nothing else, so the code in .text is byte-identical to stock.
LDSO=""
for CAND in /lib/ld-musl-*.so.1; do [ -f "$CAND" ] && LDSO="$CAND"; done
[ -z "$LDSO" ] && { printf '  no musl loader found\n'; exit 1; }
cp "$WORK/inst/lib/libc.so" "$LDSO.patched" && mv "$LDSO.patched" "$LDSO" || {
	printf '  could not replace %s\n' "$LDSO"; exit 1
}
printf '  %-14s %s\n' "replaced" "$LDSO"

# If the new libc were broken, everything below would fail in confusing ways.
if ! gdb --version >/dev/null 2>&1; then
	printf '  gdb no longer runs against the replaced libc - stopping here\n'
	exit 1
fi
printf '  %-14s %s\n\n' "sanity" "gdb still runs against the replaced libc"

# The unpatched sleeper of the reproducer, unchanged. Debug info now comes from
# the replaced libc itself, so musl-dbg plays no part.
BIN=/work/sleeper-$ARCH
[ -x "$BIN" ] || { printf '  %s is missing - run ../run-on-host.sh first\n' "$BIN"; exit 1; }

case "$ARCH" in
	armhf|armv7) QEMU=/usr/bin/qemu-arm-static ;;
	aarch64)     QEMU=/usr/bin/qemu-aarch64-static ;;
esac

# Same route as the reproducer: qemu-user has no ptrace, so its gdb server is
# the only way in. On real hardware plain "attach" would do.
if [ -x "$QEMU" ]; then
	"$QEMU" -g 1235 "$BIN" >/dev/null 2>&1 &
	TARGET=$!
	sleep 2
	printf 'target remote :1235\nbreak parked\ncontinue\ndelete breakpoints\n' \
		> "$WORK/connect.gdb"
else
	"$BIN" >/dev/null 2>&1 &
	TARGET=$!
	sleep 2
	printf 'attach %s\n' "$TARGET" > "$WORK/connect.gdb"
fi

cat > "$WORK/bt.gdb" <<'EOF'
set sysroot /
set backtrace limit 64
set pagination off
set height unlimited
set width unlimited
set confirm off
set print inferior-events off
set print thread-events off
source /tmp/verify/connect.gdb
thread apply all -c bt
quit
EOF

timeout 180 gdb -q -batch -nx -x "$WORK/bt.gdb" "$BIN" >"$WORK/bt.txt" 2>&1
kill "$TARGET" 2>/dev/null; wait "$TARGET" 2>/dev/null
sed 's/^/  /' "$WORK/bt.txt"
printf '\n'

# The point of the whole exercise: a sleeping thread reaching its entry point
# with no debugger add-on involved.
if grep -q 'worker' "$WORK/bt.txt"; then
	printf 'VERDICT  plain gdb reaches the thread entry point. No add-on was loaded.\n'
else
	printf 'VERDICT  the backtrace still does not reach the application frames.\n'
fi
