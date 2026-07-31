#!/bin/sh
# Container entry point for daemon mode: build the test program, park its
# threads, then stay alive so the container can be inspected by hand.
#
# Started by ../up - not meant to be run directly.
#
# No ~/.gdbinit is written and no gdb server is started: gdb behaves exactly as
# it would anywhere else. If a debugger cannot control the process here, that
# is the environment talking, and it should be visible rather than papered
# over.
#
# If you do want the qemu route, start it by hand - qemu-arm-static is in the
# image for that:
#
#     qemu-arm-static -g 1234 ./sleeper &
#     gdb ./sleeper -ex 'set sysroot /' -ex 'target remote :1234'
#
# set sysroot / matters there, otherwise gdb pulls every library through the
# remote protocol and appears to hang.
set -u

ARCH=$(apk --print-arch 2>/dev/null || uname -m)
BIN=./sleeper-$ARCH   # per architecture: container/ is shared by all platforms

make -s >/dev/null 2>&1 || { echo "build failed"; exit 1; }

"$BIN" &
SLEEPER_PID=$!
sleep 1

case "$(uname -m)" in
	armv7l|armv6l|arm) QEMU=qemu-arm-static ;;
	aarch64)           QEMU=qemu-aarch64-static ;;
	*)                 QEMU="" ;;
esac

cat <<EOF
============================================================
 $(uname -m) - ready
============================================================
  test program   $BIN (pid $SLEEPER_PID), 3 worker threads parked
  sources        /work

    gdb $BIN
    sh entrypoint.sh          the full evidence report
EOF

[ -n "$QEMU" ] && cat <<EOF

  Emulated here, so gdb cannot control the process - qemu-user implements
  no ptrace. Via qemu's own gdb server it works:

    $QEMU -g 1234 $BIN &
    gdb $BIN -ex 'set sysroot /' -ex 'target remote :1234'
EOF

echo "============================================================"

# Keep the container alive. The parked program is the thing to look at.
wait "$SLEEPER_PID"
