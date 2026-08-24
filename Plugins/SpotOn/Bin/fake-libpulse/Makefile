# Makefile -- fake-libpulse.so.0 build (SpotOn v4.0 Soloist Integration, D-06)
#
# Builds the PulseAudio-client stub (see fake-libpulse.c) as a native
# shared object. CC/CFLAGS/LDFLAGS are overridable on the command line
# so the CI cross-compile matrix
# (.github/workflows/build-fake-libpulse.yml) can target the aarch64
# and armhf glibc toolchains without editing this file, e.g.:
#
#   make -C Plugins/SpotOn/Bin/fake-libpulse CC=aarch64-linux-gnu-gcc
#   make -C Plugins/SpotOn/Bin/fake-libpulse CC=arm-linux-gnueabihf-gcc
#
# x86_64 uses the default native `gcc` (no override needed).

CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra
LDFLAGS ?=
TARGET  := libpulse.so.0
SRC     := fake-libpulse.c

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -shared -fPIC -o $(TARGET) $(SRC) -lpthread $(LDFLAGS)

clean:
	rm -f $(TARGET)
