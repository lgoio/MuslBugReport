#!/bin/sh
# Checks the numbered patch files. Five stages, each one printed with its own
# verdict; the exit code is non-zero if any of them fails.
#
#   1  the patches are in sync with tools/ and rationale/
#   2  each patch applies with plain "patch -p1" and reproduces its generator
#      byte for byte, and all of them apply together in one stream
#   3  every generator is valid awk
#   4  run over the real musl asm, every generator wraps __syscall_cp_asm and
#      __clone in a .cfi_startproc/.cfi_endproc pair - that is the FDE which is
#      missing today
#   5  the send-ready message carries the same patches and still applies
#
# Stage 4 needs the musl sources. It uses $MUSL_DIR if that points at an
# unpacked tree, otherwise it downloads one next to this script. Stage 5 needs
# the message, which is not in git. Either one is skipped out loud rather than
# passed silently.
#
# Assembling the result and reading the FDEs back out of a built libc.so is the
# stronger check and needs a cross toolchain - patch/verify.sh does that in the
# reproducer containers.
set -u

DIR=$(cd "$(dirname "$0")" && pwd)
MUSL_VERSION=musl-1.2.6
MUSL_URL=https://musl.libc.org/releases/$MUSL_VERSION.tar.gz
CACHE=$DIR/.musl-cache
MUSL_DIR=${MUSL_DIR:-$CACHE/$MUSL_VERSION}

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT
FAILED=0

fail() { printf '    FAIL  %s\n' "$1"; FAILED=1; }
pass() { printf '    ok    %s\n' "$1"; }

PATCHES=$(ls "$DIR"/[0-9][0-9][0-9][0-9]-add-cfi-*.patch 2>/dev/null)
[ -n "$PATCHES" ] || { printf 'no patch files in %s - run make-patches.sh\n' "$DIR"; exit 1; }
COUNT=$(printf '%s\n' $PATCHES | wc -l | tr -d ' ')

arch_of() { basename "$1" .patch | sed 's/^[0-9]*-add-cfi-//'; }

# -- stage 1: are the patch files what make-patches.sh would write now? ------
printf '\n=== stage 1: patch files in sync with their sources\n'
cp -r "$DIR" "$WORK/regen" || exit 1
if sh "$WORK/regen/make-patches.sh" >/dev/null 2>&1; then
	for P in $PATCHES; do
		B=$(basename "$P")
		if cmp -s "$P" "$WORK/regen/$B"; then
			pass "$B"
		else
			fail "$B is stale - run make-patches.sh"
		fi
	done
	# A generator with no patch file would go unnoticed above.
	for G in "$DIR"/tools/add-cfi.*.awk; do
		A=$(basename "$G" .awk | sed 's/^add-cfi\.//')
		ls "$DIR"/[0-9][0-9][0-9][0-9]-add-cfi-"$A".patch >/dev/null 2>&1 \
			|| fail "tools/add-cfi.$A.awk has no patch file"
	done
else
	fail "make-patches.sh did not run"
fi

# -- stage 2: do they apply, and do they reproduce the generators? ----------
printf '\n=== stage 2: patches apply and reproduce the generators\n'
for P in $PATCHES; do
	A=$(arch_of "$P")
	B=$(basename "$P")
	T=$WORK/apply-$A
	mkdir -p "$T/tools"
	if (cd "$T" && patch -p1 --silent < "$P") 2>/dev/null; then
		if cmp -s "$T/tools/add-cfi.$A.awk" "$DIR/tools/add-cfi.$A.awk"; then
			pass "$B"
		else
			fail "$B applied but the result differs from tools/add-cfi.$A.awk"
		fi
	else
		fail "$B does not apply with patch -p1"
	fi
done

# The mail carries all of them in one message, so they have to apply as one
# stream too - a stray line between two patches shows up here and nowhere else.
T=$WORK/apply-all
mkdir -p "$T/tools"
cat $PATCHES > "$WORK/all.patch"
if (cd "$T" && patch -p1 --silent < "$WORK/all.patch") 2>/dev/null; then
	SAME=yes
	for P in $PATCHES; do
		A=$(arch_of "$P")
		cmp -s "$T/tools/add-cfi.$A.awk" "$DIR/tools/add-cfi.$A.awk" || SAME=no
	done
	[ "$SAME" = yes ] && pass "all $COUNT in one stream" \
		|| fail "applying all $COUNT at once gives a different result"
else
	fail "the $COUNT patches do not apply as one stream"
fi

# -- stage 3: is every generator valid awk? --------------------------------
printf '\n=== stage 3: generators are valid awk\n'
for G in "$DIR"/tools/add-cfi.*.awk; do
	A=$(basename "$G" .awk | sed 's/^add-cfi\.//')
	if LC_ALL=C awk -f "$G" /dev/null >/dev/null 2>"$WORK/awkerr"; then
		pass "add-cfi.$A.awk"
	else
		fail "add-cfi.$A.awk: $(head -1 "$WORK/awkerr")"
	fi
done

# -- stage 4: does each generator produce the FDE that is missing today? ----
printf '\n=== stage 4: FDE coverage on the real musl asm\n'
SKIP4=no
if [ ! -d "$MUSL_DIR/src/thread" ]; then
	mkdir -p "$CACHE"
	printf '    fetching %s\n' "$MUSL_VERSION"
	if ! (cd "$CACHE" && wget -q "$MUSL_URL" -O "$MUSL_VERSION.tar.gz" \
			&& tar -xzf "$MUSL_VERSION.tar.gz"); then
		printf '    SKIPPED - no musl sources and none could be downloaded\n'
		printf '    set MUSL_DIR to an unpacked tree to run this stage\n'
		SKIP4=yes
	fi
fi
COMMON=$MUSL_DIR/tools/add-cfi.common.awk
if [ "$SKIP4" = no ] && [ ! -f "$COMMON" ]; then
	printf '    SKIPPED - %s is not a musl tree\n' "$MUSL_DIR"
	SKIP4=yes
fi
# The symbols every sleeping thread parks on, and the bottom of every thread
# stack. Each has to end up inside a .cfi_startproc/.cfi_endproc pair.
SYMS="__syscall_cp_asm __cp_begin __cp_end __clone"

covered() { # covered <generated-asm> <symbol>
	LC_ALL=C awk -v sym="$2" '
		/^\.cfi_startproc/ { open = 1 }
		/^\.cfi_endproc/   { open = 0 }
		$0 ~ "^" sym ":"   { if (open) found = 1 }
		END { exit !found }
	' "$1"
}

check_coverage() {
	for G in "$DIR"/tools/add-cfi.*.awk; do
		A=$(basename "$G" .awk | sed 's/^add-cfi\.//')
		SRCDIR=$MUSL_DIR/src/thread/$A
		if [ ! -d "$SRCDIR" ]; then
			fail "add-cfi.$A.awk: $MUSL_DIR has no src/thread/$A"
			continue
		fi
		MISSING=""
		for F in "$SRCDIR"/syscall_cp.s "$SRCDIR"/clone.s; do
			[ -f "$F" ] || { MISSING="$MISSING $(basename "$F")(absent)"; continue; }
			OUTF=$WORK/$A-$(basename "$F")
			if ! LC_ALL=C awk -f "$COMMON" -f "$G" "$F" < "$F" \
					> "$OUTF" 2>"$WORK/awkerr"; then
				MISSING="$MISSING $(basename "$F")($(head -1 "$WORK/awkerr"))"
				continue
			fi
			# Unbalanced procs would not assemble.
			O=$(grep -c '^\.cfi_startproc' "$OUTF")
			C=$(grep -c '^\.cfi_endproc' "$OUTF")
			[ "$O" = "$C" ] \
				|| MISSING="$MISSING $(basename "$F")($O startproc/$C endproc)"
			for S in $SYMS; do
				grep -q "^$S:" "$F" || continue
				covered "$OUTF" "$S" || MISSING="$MISSING $S"
			done
		done
		if [ -z "$MISSING" ]; then
			pass "add-cfi.$A.awk covers$(printf ' %s' $SYMS)"
		else
			fail "add-cfi.$A.awk leaves uncovered:$MISSING"
		fi
	done
}
[ "$SKIP4" = no ] && check_coverage

# -- stage 5: the message that actually gets sent --------------------------
# Not in git, so this stage only runs once make-inline-mail.sh has been run.
INLINE=$DIR/../mail-to-musl-inline.txt
printf '\n=== stage 5: the send-ready message\n'
if [ ! -f "$INLINE" ]; then
	printf '    SKIPPED - %s does not exist yet\n' "$(basename "$INLINE")"
else
	# Rebuild inside the copy made in stage 1, so this compares against the
	# file on disk instead of grading a copy it just wrote itself.
	cp "$DIR/../mail-to-musl.txt" "$WORK/" 2>/dev/null
	if sh "$WORK/regen/make-inline-mail.sh" >/dev/null 2>&1 \
			&& cmp -s "$WORK/mail-to-musl-inline.txt" "$INLINE"; then
		pass "in sync with the cover letter and the patches"
	else
		fail "$(basename "$INLINE") is stale - run make-inline-mail.sh"
	fi

	T=$WORK/apply-mail
	mkdir -p "$T/tools"
	if (cd "$T" && patch -p1 --silent < "$INLINE") 2>/dev/null; then
		SAME=yes
		for P in $PATCHES; do
			A=$(arch_of "$P")
			cmp -s "$T/tools/add-cfi.$A.awk" "$DIR/tools/add-cfi.$A.awk" || SAME=no
		done
		[ "$SAME" = yes ] \
			&& pass "patch -p1 on the mail reproduces all $COUNT generators" \
			|| fail "the mail applies but a generator comes out different"
	else
		fail "the mail does not apply with patch -p1"
	fi
fi

printf '\n'
if [ "$FAILED" = 0 ]; then
	printf '=== all checks passed (%d patches)\n\n' "$COUNT"
else
	printf '=== there were failures\n\n'
fi
exit $FAILED
