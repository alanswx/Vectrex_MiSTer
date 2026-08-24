#!/usr/bin/env bash
# Build and run the Vectrex core under ghdl, extracting beam segments.
#
#   ./run.sh <cart.bin> [run_ms] [out.txt]
#
# Segments land in out.txt (default seg.txt) and can be diffed against
# tools/goldenref output with tools/goldenref/compare.py. Stateful experiments
# can override ANALOG_MODEL, ANALOG_LIVE_INPUTS, ANALOG_SETTLE_SHIFT,
# ANALOG_ACQUIRE_SHIFT, ANALOG_DROOP_SHIFT, ANALOG_DROOP_ENABLE, and
# ANALOG_ZERO_SHIFT without editing RTL.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${BUILD:-$ROOT/sim/build}"

CART="${1:?usage: run.sh <cart.bin> [run_ms] [out.txt] [warm_ms]}"
# Resolved before the cd into the build directory below.
CART="$(cd "$(dirname "$CART")" && pwd)/$(basename "$CART")"
RUN_MS="${2:-100}"
OUT="${3:-seg.txt}"
# A second reset a few hundred ms in makes the BIOS skip its title sequence,
# the same trick Vectrex.sv uses for "Skip logo". Worth it because the intro
# costs seconds of emulated time, and seconds are expensive here. Note vecx
# cannot match this (its reset wipes RAM), so only use it when comparing a
# static pattern, where frame alignment does not matter.
WARM_MS="${4:-0}"
# Time to tap button 1, which is what gets a game off its title screen.
PRESS_MS="${5:-0}"
PRESS_COUNT="${6:-1}"
PRESS_EVERY="${7:-1000}"
PRESS_BTN="${8:-1}"
PRESS_HOLD="${9:-15}"
ANALOG_MODEL="${ANALOG_MODEL:-0}"
ANALOG_LIVE_INPUTS="${ANALOG_LIVE_INPUTS:-1}"
ANALOG_SETTLE_SHIFT="${ANALOG_SETTLE_SHIFT:-2}"
ANALOG_ACQUIRE_SHIFT="${ANALOG_ACQUIRE_SHIFT:-6}"
ANALOG_DROOP_SHIFT="${ANALOG_DROOP_SHIFT:-30}"
ANALOG_DROOP_ENABLE="${ANALOG_DROOP_ENABLE:-1}"
ANALOG_ZERO_SHIFT="${ANALOG_ZERO_SHIFT:-6}"
BIOS_FACTORY="${BIOS_FACTORY:-0}"
TRACE_CURVE_TOL="${TRACE_CURVE_TOL:-0}"
STABLE_CPU_ENABLE="${STABLE_CPU_ENABLE:-0}"

# ---------------------------------------------------------------- backend --
# mcode is the default when both backends are installed, but llvm is roughly
# 1.5x faster here, which matters because the core simulates at well under
# real time. Ubuntu's ghdl-llvm looks for libLLVM-18.so.18.1 while libllvm18
# installs it as libLLVM.so.18.1, so bridge the name if it is missing.
if [ -x /usr/bin/ghdl-llvm ]; then
	SONAME=libLLVM-18.so.18.1
	if ! ldconfig -p | grep -q "$SONAME"; then
		REAL=$(ls /usr/lib/x86_64-linux-gnu/libLLVM.so.18.1 2>/dev/null || true)
		if [ -n "$REAL" ]; then
			mkdir -p "$BUILD/lib"
			ln -sf "$REAL" "$BUILD/lib/$SONAME"
			export LD_LIBRARY_PATH="$BUILD/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
		fi
	fi
	if GHDL_BACKEND=llvm ghdl --version >/dev/null 2>&1; then
		export GHDL_BACKEND=llvm
		OPT=-O3
	fi
fi
OPT="${OPT:-}"
echo "backend: ${GHDL_BACKEND:-mcode} ${OPT}"

# -fsynopsys for ieee.std_logic_unsigned, which the core and the 6522 use.
FLAGS="--std=08 -fsynopsys -frelaxed $OPT"

mkdir -p "$BUILD"
cd "$BUILD"

# Cartridge as one decimal byte per line, which is what the testbench reads.
od -An -v -tu1 -w1 "$CART" | tr -d ' ' > cart.hex
SIZE=$(wc -l < cart.hex)

# cart_mask is ANDed with the CPU address, so it must be size-1 rounded up to
# a power of two.
MASK=1
while [ "$MASK" -lt "$SIZE" ]; do MASK=$((MASK * 2)); done
MASK=$((MASK - 1))
echo "cart: $SIZE bytes, mask $MASK"

# shellcheck disable=SC2086
ghdl -a $FLAGS \
	"$ROOT/sim/gen_mem_sim.vhd" \
	"$ROOT/rtl/bios_rom.vhd" \
	"$ROOT/rtl/bios_factory_rom.vhd" \
	"$ROOT/rtl/sp0256_al2_decoded.vhd" \
	"$ROOT/rtl/sp0256.vhd" \
	"$ROOT/rtl/m6522a.vhd" \
	"$ROOT/rtl/cpu09l_128a.vhd" \
	"$ROOT/sim/mc6809_sim.vhd" \
	"$ROOT/sim/ym2149_sim.vhd" \
	"$ROOT/rtl/vectrex_analog_pkg.vhd" \
	"$ROOT/rtl/vectrex_analog_frontend.vhd" \
	"$ROOT/rtl/vectrex.vhd" \
	"$ROOT/sim/tb_vectrex.vhd" 2>&1 | grep -v "shared variable" || true

# shellcheck disable=SC2086
ghdl -e $FLAGS tb_vectrex 2>&1 | grep -vE "compressor|default configuration" || true

echo "running ${RUN_MS}ms (expect roughly 0.7s of wall clock per emulated ms)"
if [ -x ./tb_vectrex ]; then
	./tb_vectrex -gCART_FILE=cart.hex -gCART_MASK=$MASK \
		-gRUN_MS="$RUN_MS" -gWARM_MS="$WARM_MS" -gSTABLE_CPU_ENABLE="$STABLE_CPU_ENABLE" -gPRESS_MS="$PRESS_MS" -gPRESS_COUNT="$PRESS_COUNT" -gPRESS_EVERY="$PRESS_EVERY" -gPRESS_BTN="$PRESS_BTN" -gPRESS_HOLD="$PRESS_HOLD" -gANALOG_MODEL="$ANALOG_MODEL" -gANALOG_LIVE_INPUTS="$ANALOG_LIVE_INPUTS" -gANALOG_SETTLE_SHIFT="$ANALOG_SETTLE_SHIFT" -gANALOG_ACQUIRE_SHIFT="$ANALOG_ACQUIRE_SHIFT" -gANALOG_DROOP_SHIFT="$ANALOG_DROOP_SHIFT" -gANALOG_DROOP_ENABLE="$ANALOG_DROOP_ENABLE" -gANALOG_ZERO_SHIFT="$ANALOG_ZERO_SHIFT" -gBIOS_FACTORY="$BIOS_FACTORY" -gTRACE_CURVE_TOL="$TRACE_CURVE_TOL" -gDUMP_FILE="$OUT" --ieee-asserts=disable
else
	# mcode does not produce a binary; it runs through the driver.
	# shellcheck disable=SC2086
	ghdl -r $FLAGS tb_vectrex -gCART_FILE=cart.hex -gCART_MASK=$MASK \
		-gRUN_MS="$RUN_MS" -gWARM_MS="$WARM_MS" -gSTABLE_CPU_ENABLE="$STABLE_CPU_ENABLE" -gPRESS_MS="$PRESS_MS" -gPRESS_COUNT="$PRESS_COUNT" -gPRESS_EVERY="$PRESS_EVERY" -gPRESS_BTN="$PRESS_BTN" -gPRESS_HOLD="$PRESS_HOLD" -gANALOG_MODEL="$ANALOG_MODEL" -gANALOG_LIVE_INPUTS="$ANALOG_LIVE_INPUTS" -gANALOG_SETTLE_SHIFT="$ANALOG_SETTLE_SHIFT" -gANALOG_ACQUIRE_SHIFT="$ANALOG_ACQUIRE_SHIFT" -gANALOG_DROOP_SHIFT="$ANALOG_DROOP_SHIFT" -gANALOG_DROOP_ENABLE="$ANALOG_DROOP_ENABLE" -gANALOG_ZERO_SHIFT="$ANALOG_ZERO_SHIFT" -gBIOS_FACTORY="$BIOS_FACTORY" -gTRACE_CURVE_TOL="$TRACE_CURVE_TOL" -gDUMP_FILE="$OUT" --ieee-asserts=disable
fi

echo "segments written to $BUILD/$OUT"
