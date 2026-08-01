#!/bin/sh
# Builds the send-ready message from the cover letter and the patch files:
#
#     ../mail-to-musl.txt        the cover letter, written by hand
#     NNNN-add-cfi-*.patch       output of make-patches.sh
#  -> ../mail-to-musl-inline.txt what actually gets sent
#
# The per-patch "Subject: [PATCH n/7] ..." line becomes a banner, because in one
# message there is only one subject. Everything below it is copied through
# unchanged, so the diffs stay appliable with "patch -p1" straight from the mail.
#
# The result is not in git - it is regenerated, never edited.
set -eu

DIR=$(cd "$(dirname "$0")" && pwd)
COVER=$DIR/../mail-to-musl.txt
OUT=$DIR/../mail-to-musl-inline.txt
RULE=========================================================================

[ -f "$COVER" ] || { printf 'missing %s\n' "$COVER" >&2; exit 1; }
PATCHES=$(ls "$DIR"/[0-9][0-9][0-9][0-9]-add-cfi-*.patch 2>/dev/null) \
	|| { printf 'no patch files - run make-patches.sh\n' >&2; exit 1; }

{
	cat "$COVER"
	for P in $PATCHES; do
		ARCH=$(basename "$P" .patch | sed 's/^[0-9]*-add-cfi-//')
		printf '\n\n%s\n' "$RULE"
		printf '%s: add tools/add-cfi.%s.awk\n' "$ARCH" "$ARCH"
		printf '%s\n\n' "$RULE"
		# Drop the Subject line and the blank line under it; the banner
		# above says the same thing.
		sed '1,2d' "$P"
	done
} > "$OUT"

printf '  %s\n' "$OUT"
printf '  %s lines, %s patches\n' "$(wc -l < "$OUT" | tr -d ' ')" \
	"$(printf '%s\n' $PATCHES | wc -l | tr -d ' ')"
