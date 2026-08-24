#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${BUILD:-$ROOT/sim/build-analog}"
FLAGS="--std=08 -frelaxed"

mkdir -p "$BUILD"
cd "$BUILD"
ghdl -a $FLAGS "$ROOT/rtl/vectrex_analog_pkg.vhd" \
	"$ROOT/rtl/vectrex_analog_frontend.vhd" \
	"$ROOT/sim/tb_vectrex_analog_frontend.vhd"
ghdl -e $FLAGS tb_vectrex_analog_frontend
ghdl -r $FLAGS tb_vectrex_analog_frontend --assert-level=error --stop-time=100us
