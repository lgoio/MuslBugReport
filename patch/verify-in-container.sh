#!/bin/sh
# Checks the add-cfi generators in patch/tools/. Runs inside one of the
# reproducer containers; patch/verify.sh starts it from the host.
#
# Stage 1 assembles the two affected files with and without the generator and
# asks whether an FDE covers each symbol on the blocking-call path. That is the
# whole claim, and it needs neither a full build nor a debugger.
#
# Stage 2 (--full) drops the generator into an otherwise untouched musl tree,
# builds it, replaces the container's libc and takes a backtrace with plain gdb -
# no Python unwinder, no gdb add-on of any kind. That is what patching Alpine
# amounts to. Slow under emulation.
set -u

MUSL=musl-1.2.6
URL=https://musl.libc.org/releases/$MUSL.tar.gz
TOOLS=/patch/tools
WORK=/tmp/verify
FULL=no
[ "${1:-}" = "--full" ] && FULL=yes

ARCH=$(apk --print-arch)
# Alpine's architecture names and musl's do not always match.
case "$ARCH" in
	armhf|armv7) ASMDIR=arm ;;
	aarch64)     ASMDIR=aarch64 ;;
	riscv64)     ASMDIR=riscv64 ;;
	ppc64le)     ASMDIR=powerpc64 ;;
	s390x)       ASMDIR=s390x ;;
	loongarch64) ASMDIR=loongarch64 ;;
	x86_64|x86)
		printf 'musl covers %s with a generator of its own already.\n' "$ARCH"
		printf 'There is nothing to verify here.\n'
		exit 0 ;;
	*)
		printf '%s is affected too, but this reproducer has no image for it.\n' "$ARCH"
		exit 0 ;;
esac
GEN=$TOOLS/add-cfi.$ASMDIR.awk
[ -f "$GEN" ] || { printf 'no generator for %s in %s\n' "$ASMDIR" "$TOOLS"; exit 1; }

line() { printf '  ----------------------------------------------------------\n'; }
SYMS="__syscall_cp_asm __cp_begin __cp_end __clone"

printf '=== generator verification - %s (musl arch: %s)\n\n' "$ARCH" "$ASMDIR"

# -- sources ---------------------------------------------------------------
rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK" || exit 1
if ! wget -q "$URL" -O "$MUSL.tar.gz"; then
	printf 'could not download %s\n' "$URL"
	exit 1
fi
tar -xzf "$MUSL.tar.gz" || exit 1
printf 'sources\n'
printf '  musl         %s (no source file is edited)\n' "$MUSL"
printf '  generator    %s\n' "$(basename "$GEN")"
printf '  compiler     %s\n' "$(gcc --version | head -1)"
printf '\n'

# -- stage 1: does the generator produce the missing FDEs? -----------------
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
printf '  %-18s %-10s %s\n' "symbol" "stock" "generated"
line
STAGE1_FAIL=0
for SRC in syscall_cp clone; do
	F=$MUSL/src/thread/$ASMDIR/$SRC.s
	# stock: straight through the compiler driver, which is what musl's
	# Makefile does when ADD_CFI is off - the state on this architecture today
	gcc -c -g "$F" -o "$WORK/stock-$SRC.o" 2>/dev/null
	# generated: through the awk pair first, exactly as the Makefile would
	LC_ALL=C awk -f "$MUSL/tools/add-cfi.common.awk" -f "$GEN" "$F" \
		| gcc -c -g -x assembler -o "$WORK/gen-$SRC.o" - 2>"$WORK/as-$SRC.log" \
		|| { printf '  assembling generated %s failed:\n' "$SRC"; \
		     sed 's/^/    /' "$WORK/as-$SRC.log"; exit 1; }
done
for SYM in $SYMS; do
	BEFORE=no; AFTER=no
	for SRC in syscall_cp clone; do
		covered "$WORK/stock-$SRC.o" "$SYM" && BEFORE=yes
		covered "$WORK/gen-$SRC.o" "$SYM" && AFTER=yes
	done
	printf '  %-18s %-10s %s\n' "$SYM" "$BEFORE" "$AFTER"
	[ "$AFTER" = no ] && STAGE1_FAIL=$((STAGE1_FAIL + 1))
done
line
printf '\n'
if [ "$STAGE1_FAIL" -eq 0 ]; then
	printf 'VERDICT  every symbol on the cancellable-syscall path now has an FDE.\n'
else
	printf 'VERDICT  %d symbols still have no FDE - the generator is incomplete.\n' "$STAGE1_FAIL"
fi
printf '\n'

[ "$FULL" = no ] && {
	printf '(stage 2 skipped - pass --full to build musl and take a real backtrace)\n'
	exit 0
}

# -- stage 2: a real backtrace against a musl built with the generator -----
printf 'stage 2 - backtrace against a musl built with the generator\n\n'
apk add --no-cache make >/dev/null 2>&1

# The generator is the entire change. Nothing under src/ is touched, which is
# also why a build without -g still works: configure leaves ADD_CFI off and the
# assembly goes through unannotated, exactly as before.
cp "$GEN" "$MUSL/tools/"

# riscv64, powerpc64 and s390x have no end-of-stack marker of their own, so the
# optional companion patch adds one - a comment, which is inert when this
# generator does not run. Architectures that already carry musl's own marker
# (the zeroed frame pointer) are not in the patch and skip this quietly.
if [ -f /patch/clone-end-of-stack.patch ]; then
	if ( cd "$MUSL" && patch -p1 --batch --silent --dry-run \
			< /patch/clone-end-of-stack.patch >/dev/null 2>&1 ); then
		( cd "$MUSL" && patch -p1 --batch --silent < /patch/clone-end-of-stack.patch )
		printf '  %-14s %s\n' "marker" "clone-end-of-stack.patch applied"
	else
		printf '  %-14s %s\n' "marker" "not needed here (musl marks it already)"
	fi
fi

cd "$WORK/$MUSL" || exit 1
if ! ./configure --prefix="$WORK/inst" CFLAGS="-g -O2" \
		>"$WORK/configure.log" 2>&1; then
	tail -5 "$WORK/configure.log"; exit 1
fi
printf '  %-14s %s\n' "ADD_CFI" "$(grep -E '^ADD_CFI' config.mak)"
if ! make -j"$(nproc)" install >"$WORK/build.log" 2>&1; then
	printf '  build failed:\n'
	grep -E 'Error|error:' "$WORK/build.log" | grep -v Werror | head -10 | sed 's/^/    /'
	exit 1
fi
printf '  %-14s %s\n' "built" "$WORK/inst/lib/libc.so"

# Replace the container's musl with it. This is what patching Alpine amounts to,
# and it keeps the reproducer's own sleeper and gdb machinery in play instead of
# some special-purpose binary.
#
# The rename is atomic on purpose: writing into the file in place would corrupt
# the mapping of every process already running against it. Processes started
# afterwards - the sleeper, gdb - pick up the new one.
#
# Safe because .cfi_* directives emit a debug section and no instructions: the
# code in .text is byte-identical to stock.
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

# The reproducer's own sleeper, unchanged. Debug info now comes from the
# replaced libc itself, so musl-dbg plays no part.
BIN=/work/sleeper-$ARCH
[ -x "$BIN" ] || { printf '  %s is missing - run ../run-on-host.sh first\n' "$BIN"; exit 1; }

case "$ARCH" in
	armhf|armv7) QEMU=/usr/bin/qemu-arm-static ;;
	aarch64)     QEMU=/usr/bin/qemu-aarch64-static ;;
	riscv64)     QEMU=/usr/bin/qemu-riscv64-static ;;
	ppc64le)     QEMU=/usr/bin/qemu-ppc64le-static ;;
	s390x)       QEMU=/usr/bin/qemu-s390x-static ;;
	loongarch64) QEMU=/usr/bin/qemu-loongarch64-static ;;
	*)           QEMU="" ;;
esac

# Same route as the reproducer: qemu-user has no ptrace, so its gdb server is
# the only way in. On real hardware plain "attach" would do.
if [ -n "$QEMU" ] && [ -x "$QEMU" ]; then
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

# Only arm and aarch64 carry musl's own end-of-stack marker (the frame pointer
# is zeroed in the child half of clone.s, added in 1.2.6). Where it is absent
# the generator has nothing to key on, so __clone still repeats.
if grep -c '__clone' "$WORK/bt.txt" | grep -qv '^[0-4]$'; then
	printf '         __clone still repeats - this architecture has no marker in\n'
	printf '         clone.s for the generator to key on.\n'
fi
