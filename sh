#!/bin/sh
# Shell into one of the containers started by ./up.
#
#     ./sh              armv7 by default
#     ./sh aarch64      pick another
#     ./sh armv7 gdb -q -batch -nx -x /work/gdb_plain_command_file /tmp/sleeper
set -u

# TIMEOUT=<seconds> bounds the call, so a wedged gdb cannot block the terminal.
TIMEOUT=${TIMEOUT:-}
NAME_PREFIX=bugreport
LABEL=${1:-armv7}
[ $# -gt 0 ] && shift

DOCKER="docker"
docker info >/dev/null 2>&1 || DOCKER="sudo docker"

NAME="$NAME_PREFIX-$LABEL"
if ! $DOCKER ps --format '{{.Names}}' | grep -q "^${NAME}$"; then
	echo "$NAME is not running - start it with: ./up $LABEL"
	exit 1
fi

# -t only when there really is a terminal, otherwise "./sh armv7 make report"
# fails with "cannot attach stdin to a TTY-enabled container".
TTY=""
[ -t 0 ] && [ -t 1 ] && TTY="-t"

if [ $# -eq 0 ]; then
	[ -z "$TTY" ] && { echo "no terminal - pass a command, e.g. ./sh $LABEL make report"; exit 1; }
	exec $DOCKER exec -i $TTY "$NAME" /bin/sh
else
	if [ -n "$TIMEOUT" ]; then
		exec timeout "$TIMEOUT" $DOCKER exec -i $TTY "$NAME" "$@"
	fi
	exec $DOCKER exec -i $TTY "$NAME" "$@"
fi
