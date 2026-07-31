# Forwards to container/, so "make" works from the project root too.

.PHONY: all clean

all clean:
	$(MAKE) -C container $@
