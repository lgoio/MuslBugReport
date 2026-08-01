#!/bin/sh
# Builds the numbered patch files from their two sources:
#
#     tools/add-cfi.<arch>.awk    the generator, the part that is submitted
#     rationale/<arch>.txt        the prose that goes above the diff
#
# The .patch files are output, not source - do not edit them by hand, the next
# run overwrites them. Edit the generator or the rationale and run this again,
# then check-patches.sh.
set -eu

DIR=$(cd "$(dirname "$0")" && pwd)

# Submission order: the two architectures the bug was measured on first, then
# the rest. riscv32 is last because it came after the others.
ORDER="arm aarch64 riscv64 powerpc64 s390x loongarch64 riscv32"
TOTAL=$(printf '%s\n' $ORDER | wc -l | tr -d ' ')

rm -f "$DIR"/[0-9][0-9][0-9][0-9]-add-cfi-*.patch

N=0
for ARCH in $ORDER; do
	N=$((N + 1))
	GEN="$DIR/tools/add-cfi.$ARCH.awk"
	WHY="$DIR/rationale/$ARCH.txt"
	OUT=$(printf '%s/%04d-add-cfi-%s.patch' "$DIR" "$N" "$ARCH")

	[ -f "$GEN" ] || { printf 'missing %s\n' "$GEN" >&2; exit 1; }
	[ -f "$WHY" ] || { printf 'missing %s\n' "$WHY" >&2; exit 1; }

	# A file created from /dev/null is one hunk covering the whole generator.
	LINES=$(wc -l < "$GEN" | tr -d ' ')

	{
		printf 'Subject: [PATCH %d/%d] %s: add tools/add-cfi.%s.awk\n\n' \
			"$N" "$TOTAL" "$ARCH" "$ARCH"
		cat "$WHY"
		printf '\n---\n'
		printf -- '--- /dev/null\n'
		printf -- '+++ b/tools/add-cfi.%s.awk\n' "$ARCH"
		printf '@@ -0,0 +1,%d @@\n' "$LINES"
		sed 's/^/+/' "$GEN"
	} > "$OUT"

	printf '  %s  (%d lines)\n' "$(basename "$OUT")" "$LINES"
done

printf '\n  %d patches written to %s\n' "$TOTAL" "$DIR"
printf '  run %s/check-patches.sh next\n' "$(basename "$DIR")"
