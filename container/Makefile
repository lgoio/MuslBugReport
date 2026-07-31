# Builds the test program. Nothing else.
#
# The name carries the architecture because container/ is bind-mounted and
# shared by every platform: with a single ./sleeper the last build wins, make
# then considers it up to date, and the next container tries to execute a
# foreign binary ("not found", exit 127).

ARCH   ?= $(shell apk --print-arch 2>/dev/null || uname -m)
CC     ?= gcc
CFLAGS ?= -g -O2 -fno-inline -funwind-tables -pthread
BIN    ?= ./sleeper-$(ARCH)

.PHONY: all clean

all: $(BIN)

$(BIN): sleeper.c
	$(CC) $(CFLAGS) $< -o $@

clean:
	rm -f ./sleeper-*
