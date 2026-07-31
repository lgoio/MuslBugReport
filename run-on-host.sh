#!/bin/sh
# One-shot entry point for the musl unwind report. Run this on the host; it
# checks the prerequisites, offers to install what is missing, then builds and
# runs the experiment on every platform.
#
# The subject is musl upstream, not Alpine: musl generates CFI for its own
# assembly via tools/add-cfi.$ARCH.awk, and that file exists only for i386 and
# x86_64. On arm and aarch64 configure therefore sets ADD_CFI=no, no FDE covers
# __cp_begin, and no sleeping thread can be unwound.
#
#     ./run-on-host.sh
#
# Assumes a Debian or Ubuntu host. Nothing is installed without asking, and
# when stdin is not a terminal every question defaults to "no", so the script
# only reports what would be needed instead of changing the machine.
set -u

WORKDIR=$(cd "$(dirname "$0")" && pwd)
RESULTS="$WORKDIR/results"
IMAGE_PREFIX=alpine-bugreport

# docker platform : label, used for the image tag and the result file.
# The labels are Alpine's own architecture names.
PLATFORMS="linux/amd64:x86_64 linux/arm/v6:armhf linux/arm/v7:armv7 linux/arm64:aarch64"

say()  { printf '%s\n' "$*"; }
head1() { printf '\n=== %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

ASSUME_YES=no
for arg in "$@"; do
	case "$arg" in
		-y|--yes) ASSUME_YES=yes ;;
		-h|--help)
			say "usage: $0 [-y|--yes]"
			say "  -y   answer every question with yes (installs without asking)"
			exit 0 ;;
	esac
done

# Ask a yes/no question. Enter confirms. Without a terminal nothing is
# installed unless --yes was given - a script run unattended should not change
# the machine on its own.
ask() {
	if [ "$ASSUME_YES" = yes ]; then
		say "    $1 [Y/n] y   (--yes)"
		return 0
	fi
	if [ ! -t 0 ]; then
		say "    $1 -> no terminal to ask on, skipping (use --yes to accept)"
		return 1
	fi
	printf '    %s [Y/n, Enter=yes] ' "$1"
	read -r reply || return 1
	case "$reply" in
		n|N|no|NO) return 1 ;;
		*) return 0 ;;
	esac
}

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
	have sudo || die "not root and sudo is not available"
	SUDO="sudo"
fi

APT_UPDATED=no
apt_update_once() {
	[ "$APT_UPDATED" = yes ] && return 0
	$SUDO apt-get update -qq || die "apt-get update failed"
	APT_UPDATED=yes
}

apt_install() {
	apt_update_once
	say "    running: $SUDO apt-get install -y $*"
	# shellcheck disable=SC2086
	$SUDO apt-get install -y $* || die "apt-get install failed"
}

# Install the first of the given packages that can actually be installed.
# Package names differ across releases - on Ubuntu 26.04 qemu-user-static is
# only a virtual package provided by qemu-user-binfmt, and apt refuses it.
apt_install_any() {
	apt_update_once
	for pkg in "$@"; do
		if $SUDO apt-get install -y "$pkg" >/tmp/apt-try.$$ 2>&1; then
			say "    installed: $pkg"
			rm -f /tmp/apt-try.$$
			return 0
		fi
		say "    not available: $pkg"
	done
	say "    none of these could be installed: $*"
	[ -f /tmp/apt-try.$$ ] && tail -3 /tmp/apt-try.$$ | sed 's/^/      /'
	rm -f /tmp/apt-try.$$
	return 1
}

# Best effort - never fatal.
apt_install_optional() {
	apt_update_once
	$SUDO apt-get install -y "$@" >/dev/null 2>&1 \
		&& say "    installed: $*" \
		|| say "    skipped (not available): $*"
}

########################################################################
head1 "host"
say "    $( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || echo unknown )"
say "    kernel $(uname -r), arch $(uname -m)"

if ! have apt-get; then
	die "no apt-get found - this script assumes Debian or Ubuntu.
     On another distribution install docker and qemu-user-static yourself,
     then run the two docker commands documented in the Dockerfile."
fi

########################################################################
head1 "docker"
if have docker; then
	say "    docker present: $(docker --version 2>/dev/null || echo '?')"
else
	say "    docker is NOT installed."
	if ask "Install it now via apt (package docker.io)?"; then
		apt_install docker.io
	else
		die "docker is required."
	fi
fi

# The daemon has to be reachable, and we may need sudo for it.
DOCKER="docker"
if ! docker info >/dev/null 2>&1; then
	if $SUDO docker info >/dev/null 2>&1; then
		DOCKER="$SUDO docker"
		say "    note: talking to the daemon through $SUDO"
		say "          (add yourself to the 'docker' group to avoid this)"
	else
		say "    the docker daemon is not reachable."
		if ask "Try to start it (systemctl start docker)?"; then
			$SUDO systemctl start docker || die "could not start docker"
			docker info >/dev/null 2>&1 || DOCKER="$SUDO docker"
		else
			die "docker daemon not running."
		fi
	fi
fi

########################################################################
head1 "emulation"
# The real test is whether an image of that platform actually runs -
# registration details differ between qemu-user-static, binfmt-support and
# docker's own installer, so checking package names would prove nothing.
platform_works() {
	$DOCKER run --rm --platform "$1" alpine:3.23 true >/dev/null 2>&1
}

missing_platforms() {
	MISSING=""
	for ENTRY in $PLATFORMS; do
		PLAT=${ENTRY%%:*}
		platform_works "$PLAT" || MISSING="$MISSING $PLAT"
	done
	printf '%s' "${MISSING# }"
}

MISSING=$(missing_platforms)
if [ -z "$MISSING" ]; then
	say "    all platforms already run."
else
	say "    not runnable yet:$MISSING"
	if ask "Install the qemu user emulation via apt?"; then
		# Name varies by release: qemu-user-static on Debian and older Ubuntu,
		# qemu-user-binfmt since Ubuntu 26.04 (where the old name is virtual).
		apt_install_any qemu-user-static qemu-user-binfmt qemu-user-binfmt-hwe qemu-user
		apt_install_optional binfmt-support
		# Registration only takes effect once the binfmt service re-reads it.
		$SUDO systemctl restart systemd-binfmt 2>/dev/null \
			|| $SUDO systemctl restart binfmt-support 2>/dev/null \
			|| true
		say "    registered qemu handlers: $(ls /proc/sys/fs/binfmt_misc/ 2>/dev/null | grep -c qemu)"
	else
		say "    skipping apt."
	fi

	MISSING=$(missing_platforms)
	if [ -n "$MISSING" ]; then
		say "    still not runnable:$MISSING"
		if ask "Run 'docker run --privileged --rm tonistiigi/binfmt --install arm,arm64'?"; then
			$DOCKER run --privileged --rm tonistiigi/binfmt --install arm,arm64 \
				|| say "    binfmt installer failed"
		fi
		MISSING=$(missing_platforms)
	fi

	if [ -n "$MISSING" ]; then
		say ""
		say "    still not runnable:$MISSING"
		say "    Those platforms will be skipped. To fix it by hand:"
		say ""
		say "        sudo apt-get install -y qemu-user-binfmt      # Ubuntu 26.04"
		say "        sudo apt-get install -y qemu-user-static      # Debian, older Ubuntu"
		say "        sudo systemctl restart systemd-binfmt"
		say "        docker run --privileged --rm tonistiigi/binfmt --install arm,arm64"
		say ""
	else
		say "    all platforms run now."
	fi
fi

########################################################################
mkdir -p "$RESULTS"
DONE_LABELS=""
SKIPPED_LABELS=""

for ENTRY in $PLATFORMS; do
	PLAT=${ENTRY%%:*}
	LABEL=${ENTRY##*:}
	IMAGE="$IMAGE_PREFIX-$LABEL"
	OUT="$RESULTS/report-$LABEL.txt"

	head1 "$LABEL ($PLAT)"

	if ! platform_works "$PLAT"; then
		say "    not runnable on this host - skipped"
		SKIPPED_LABELS="$SKIPPED_LABELS $LABEL"
		continue
	fi

	say "    building $IMAGE"
	if ! $DOCKER build -f "$WORKDIR/docker/Dockerfile.$LABEL" -t "$IMAGE" "$WORKDIR" \
			>"$RESULTS/build-$LABEL.log" 2>&1; then
		tail -15 "$RESULTS/build-$LABEL.log" | sed 's/^/      /'
		say "    build failed - skipped (see $RESULTS/build-$LABEL.log)"
		SKIPPED_LABELS="$SKIPPED_LABELS $LABEL"
		continue
	fi

	say "    running both gdb passes"
	$DOCKER run --rm \
		--cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
		-v "$WORKDIR/container":/work -w /work "$IMAGE" /bin/sh /work/entrypoint.sh \
		>"$OUT" 2>&1
	say "    written to $OUT"
	DONE_LABELS="$DONE_LABELS $LABEL"
done

########################################################################
head1 "result"
say "    completed:$DONE_LABELS"
[ -n "$SKIPPED_LABELS" ] && say "    skipped:  $SKIPPED_LABELS"
say ""
say "    Each report contains two gdb passes over the same process:"
say "      run 1  plain gdb"
say "      run 2  same gdb plus gdb_musl_unwinder.py"
say ""
say "    Expected picture:"
say "      x86_64   both passes show the full call chain - no gap to begin with"
say "      armhf    run 1 truncated, run 2 complete"
say "      armv7    run 1 truncated, run 2 complete"
say "      aarch64  run 1 truncated, run 2 still truncated - the same gap"
say "               exists there, but the unwinder only implements the"
say "               32-bit ARM frame layout and declines on aarch64"
say ""
say "    Attach the report-*.txt files. The contrast is the argument:"
say "    same source, same Alpine version, same packages."
say ""
for LABEL in $DONE_LABELS; do
	if grep -qiE 'ptrace|Function not implemented|Operation not permitted' \
			"$RESULTS/report-$LABEL.txt" 2>/dev/null; then
		say "    WARNING: $LABEL mentions ptrace problems."
		say "    qemu-user emulates syscalls and does not implement ptrace, so"
		say "    attaching gdb to a running process cannot work under emulation."
		say "    Switch container/entrypoint.sh to the core-dump variant: let the"
		say "    program abort once the threads are parked and open the core with"
		say "    gdb - that needs no ptrace at all."
		break
	fi
done
