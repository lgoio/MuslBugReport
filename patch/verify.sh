#!/bin/sh
# Verifies patch/cfi-arm-aarch64.diff on the affected architectures.
#
#     ./patch/verify.sh              stage 1 only, a minute per architecture
#     ./patch/verify.sh --full       also builds musl and takes a real backtrace
#     ./patch/verify.sh --full armv7 one architecture
#
# Uses the images built by ../run-on-host.sh. Run that first if they are missing.
set -u

WORKDIR=$(cd "$(dirname "$0")/.." && pwd)
RESULTS="$WORKDIR/results"
IMAGE_PREFIX=alpine-bugreport

FULL=no
LABELS=""
for arg in "$@"; do
	case "$arg" in
		--full) FULL=yes ;;
		-h|--help)
			echo "usage: $0 [--full] [armhf|armv7|aarch64 ...]"
			exit 0 ;;
		*) LABELS="$LABELS $arg" ;;
	esac
done
[ -z "$LABELS" ] && LABELS="armhf armv7 aarch64 riscv64 ppc64le s390x loongarch64"

DOCKER="docker"
docker info >/dev/null 2>&1 || DOCKER="sudo docker"

# The full build is slow under emulation; a shared bound keeps one wedged
# architecture from stopping the rest.
if [ "$FULL" = yes ]; then LIMIT=3600; else LIMIT=600; fi

mkdir -p "$RESULTS"
DONE=""
for LABEL in $LABELS; do
	IMAGE="$IMAGE_PREFIX-$LABEL"
	OUT="$RESULTS/patch-$LABEL.txt"
	printf '\n=== %s\n' "$LABEL"

	if ! $DOCKER image inspect "$IMAGE" >/dev/null 2>&1; then
		printf '    image %s is missing - run ./run-on-host.sh first\n' "$IMAGE"
		continue
	fi

	printf '    verifying%s\n' "$([ "$FULL" = yes ] && echo ' (full build, this takes a while)')"
	if timeout "$LIMIT" $DOCKER run --rm \
			-v "$WORKDIR/patch":/patch \
			-v "$WORKDIR/container":/work \
			"$IMAGE" sh /patch/verify-in-container.sh \
			"$([ "$FULL" = yes ] && echo --full)" \
			> "$OUT" 2>&1; then
		DONE="$DONE $LABEL"
	else
		printf '    did not finish - see %s\n' "$OUT"
	fi
	grep '^VERDICT' "$OUT" | sed 's/^/    /'
	printf '    written to %s\n' "$OUT"
done

printf '\n=== result\n'
printf '    completed:%s\n' "${DONE:- none}"
printf '\n'
printf '    Stage 1 asks whether the patch produces the FDEs that are missing\n'
printf '    today. It reads the assembled objects and needs no ARM hardware.\n'
if [ "$FULL" = yes ]; then
	printf '    Stage 2 built musl from the patched source and took a backtrace\n'
	printf '    with plain gdb - no Python unwinder was loaded.\n'
else
	printf '    Stage 2 was skipped. Pass --full to build musl from the patched\n'
	printf '    source and take a backtrace with plain gdb.\n'
fi
