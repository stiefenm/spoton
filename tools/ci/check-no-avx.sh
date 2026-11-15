#!/usr/bin/env bash
# tools/ci/check-no-avx.sh -- GH #215 gate: the x86_64 fake-libpulse shim must run on x86_64 CPUs
# without AVX (for example Intel Celeron J4125). A shim built with a higher default ISA level
# carries %ymm / VEX instructions and kills Soloist at start with an invalid opcode.
#
# USAGE  check-no-avx.sh <elf>       an x86_64 ELF; the workflows call it for x86_64-linux only
# OUTPUT
#   (stderr, on FAIL) a short explanation of the cause
#   LAST LINE  AVX_GATE=PASS <file>                              (exit 0)
#              AVX_GATE=FAIL count=<n> first=<first hit line>    (exit 1)
#              AVX_GATE=ERROR <reason>                           (exit 2)
# EXIT  0 PASS | 1 FAIL | 2 ERROR (bad usage, objdump missing or failing, empty disassembly,
#       not an x86-64 ELF, grep failing -- an input the gate cannot judge never reads as PASS)
# Hit lines: any 256/512-bit register use (%ymm / %zmm), or a v-prefixed (VEX/EVEX) mnemonic
# with an %xmm operand (AVX-128 code such as vmulsd, which crashes the same CPUs).
# Scope: AVX only. Other above-baseline ISA (SSE4, BMI/BMI2, ...) is not scanned here; it is
# prevented by the -march=x86-64 pin in Plugins/SpotOn/Bin/fake-libpulse/Makefile.
# Core tools only (bash, objdump, grep, sed).
set -u
export LC_ALL=C   # objdump output is localised

err() { echo "AVX_GATE=ERROR $1"; exit 2; }

[ $# -eq 1 ] || err "usage: check-no-avx.sh <elf>"
FILE=$1
[ -f "$FILE" ] && [ -r "$FILE" ] || err "not a readable regular file: $FILE"
command -v objdump >/dev/null 2>&1 || err "objdump not found on PATH"

DIS=$(objdump -d "$FILE" 2>&1)
RC=$?
[ "$RC" -eq 0 ] || err "objdump -d failed (exit $RC) on $FILE: not an ELF or foreign architecture"

# The gate judges x86-64 code only. A multiarch objdump disassembles other architectures
# without complaint, and the scan below would then read their code as "no AVX" (PASS).
if ! printf '%s\n' "$DIS" | command grep -q 'file format elf64-x86-64'; then
  err "not an x86-64 ELF (no 'file format elf64-x86-64' in the objdump output): $FILE"
fi

if ! printf '%s\n' "$DIS" | command grep -q -E '^[[:space:]]*[0-9a-f]+:[[:space:]]'; then
  err "no instruction lines in the disassembly of $FILE"
fi

# grep exits 0 (hits), 1 (no hits) or >1 (error). Only 1 may read as "no hits"; an error
# must never turn into PASS.
HITS=$(printf '%s\n' "$DIS" | command grep -E '%[yz]mm[0-9]|[[:space:]]v[a-z0-9]+[[:space:]].*%xmm[0-9]')
GREP_RC=$?
[ "$GREP_RC" -le 1 ] || err "grep failed (exit $GREP_RC) while scanning the disassembly of $FILE"
if [ -z "$HITS" ]; then
  echo "AVX_GATE=PASS $FILE"
  exit 0
fi

COUNT=$(printf '%s\n' "$HITS" | wc -l | tr -d ' ')
FIRST=$(printf '%s\n' "$HITS" | head -n 1 | sed 's/^[[:space:]]*//')
{
  echo "FATAL: $FILE contains AVX instructions (GH #215)."
  echo "Soloist would crash with an invalid opcode on CPUs without AVX."
  echo "Check that ARCH_CFLAGS from Plugins/SpotOn/Bin/fake-libpulse/Makefile reached the compiler."
} >&2
echo "AVX_GATE=FAIL count=$COUNT first=$FIRST"
exit 1
