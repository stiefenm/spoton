# Makefile -- fake-libpulse.so.0 build (SpotOn v4.0 Soloist Integration, D-06)
#
# Builds the PulseAudio-client stub (see fake-libpulse.c) as a native
# shared object. CC/CFLAGS/LDFLAGS are overridable on the command line
# so the CI cross-compile matrix (.github/workflows/build-librespot.yml
# for the release zip, .github/workflows/build-fake-libpulse.yml for the
# manual build) can target the aarch64 and armhf glibc toolchains
# without editing this file, e.g.:
#
#   make -C Plugins/SpotOn/Bin/fake-libpulse CC=aarch64-linux-gnu-gcc
#   make -C Plugins/SpotOn/Bin/fake-libpulse CC=arm-linux-gnueabihf-gcc
#
# x86_64 uses the default native `gcc` (no override needed; the baseline
# ISA pin below is applied automatically).

CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra
LDFLAGS ?=
TARGET  := libpulse.so.0
SRC     := fake-libpulse.c

# GH #215: the ubuntu-latest runner's gcc defaults to a higher x86-64 ISA
# level and put AVX (%ymm) into the shim; Soloist then died with an
# invalid opcode on CPUs without AVX. The shim is pinned to the baseline
# x86-64 ISA for x86_64 compilers only; aarch64/armhf compilers report a
# non-x86_64 triple and get nothing. tools/ci/check-no-avx.sh enforces it
# in CI.
CC_MACHINE := $(shell $(CC) -dumpmachine 2>/dev/null)
ifneq ($(filter x86_64-%,$(CC_MACHINE)),)
ARCH_CFLAGS = -march=x86-64 -mtune=generic
endif

.PHONY: all clean test

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) $(ARCH_CFLAGS) -shared -fPIC -Wl,-soname,libpulse.so.0 -o $(TARGET) $(SRC) -lpthread -lm $(LDFLAGS)

# Phase 73 D-04 (S32 ring since Phase 76 D-04): host-build smoke test
# for the HTTP streaming mode (ring buffer, f32/s16->s32 conversion,
# drop-oldest, writable_size).
# Native-only -- cross-compiled test binaries cannot run on the CI
# runner (see .github/workflows/build-fake-libpulse.yml, x86_64 leg only).
test: fake-libpulse-test
	./fake-libpulse-test

fake-libpulse-test: $(SRC)
	$(CC) $(CFLAGS) $(ARCH_CFLAGS) -DFAKE_LIBPULSE_TEST -o fake-libpulse-test $(SRC) -lpthread -lm $(LDFLAGS)

clean:
	rm -f $(TARGET) fake-libpulse-test
