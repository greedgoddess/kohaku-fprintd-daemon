# Build all fingerprint MCU probe programs:  make
CC ?= gcc
CFLAGS ?= -O2 -Wall -Wextra
PROGS = fpprobe fpprobe2 fpprobe3 fpprobe4 fpprobe5 fpprobe6 fpprobe7 fpprobe8 fpprobe9

all: $(PROGS)

%: %.c cros_ec_compat.h
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f $(PROGS)

.PHONY: all clean
