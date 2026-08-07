#!/usr/bin/env python3
"""Generate cal.bin: a boot-to-pattern calibration cartridge.

Draws, every frame, with no input required (which is what makes it usable
over the remote hardware loop, in simulation, and one day on a real
Vectrex):

  - a full-bright reference line (z=$7F) at the top
  - a 14-step intensity ladder, z = 8,16,...,112, one line per step
  - a dwell pair: two lines of equal length at equal z=$50, one drawn
    with a fast beam (scale $18 x delta $7E) and one ~5x slower
    (scale $78 x delta $1A); on a real CRT the slow one is brighter
  - a dot row at z=$50 with Vec_Dot_Dwell = 1, 5, 20, 80; on a real CRT
    brightness rises with dwell

BIOS entry points used (each verified by disassembling refs/vecx/rom.dat,
see docs/accuracy-plan.md workstream 1):

  $F1AA DP_to_D0      $F192 Wait_Recal     $F354 Reset0Ref
  $F2AB Intensity_a   $F2FC Moveto_d_7F (A=y,B=x, sets its own scale)
  $F3DF Draw_Line_d (A=dy,B=dx)            $F2C5 Dot_here
  scale = VIA T1 lo latch, direct page $04 (DP=$D0)
  Vec_Dot_Dwell = $C828

Coordinate mapping, measured against vecx (tools/goldenref): Moveto_d_7F
displacement is coord x 127 integrator units (usable x roughly +/-129,
y +/-161 before the rails), and a draw's length is delta x scale. Naive
Moveto_d at scale $FF rails the integrators, which is how the first
version of this cart drew nothing.

Usage: make_calcart.py [-o cal.bin]
"""

from __future__ import annotations

import argparse

DP_TO_D0, WAIT_RECAL, RESET0REF = 0xF1AA, 0xF192, 0xF354
INTENSITY_A, MOVETO_D_7F, DRAW_LINE_D = 0xF2AB, 0xF2FC, 0xF3DF
DOT_HERE = 0xF2C5
VEC_DOT_DWELL = 0xC828

code = bytearray()


def emit(*b):
    code.extend(b)


def jsr(addr):
    emit(0xBD, addr >> 8, addr & 0xFF)


def lda(v):
    emit(0x86, v & 0xFF)


def ldb(v):
    emit(0xC6, v & 0xFF)


def ldd(a, b):
    emit(0xCC, a & 0xFF, b & 0xFF)


def scale(v):
    ldb(v)
    emit(0xD7, 0x04)          # STB <$04 (T1 lo latch, DP=$D0)


def line(y, x, z, draw_scale, dy, dx):
    jsr(RESET0REF)
    lda(z)
    jsr(INTENSITY_A)
    ldd(y, x)
    jsr(MOVETO_D_7F)
    scale(draw_scale)
    ldd(dy, dx)
    jsr(DRAW_LINE_D)


def dot(y, x, z, dwell):
    jsr(RESET0REF)
    lda(z)
    jsr(INTENSITY_A)
    ldb(dwell)
    emit(0xF7, VEC_DOT_DWELL >> 8, VEC_DOT_DWELL & 0xFF)   # STB $C828
    ldd(y, x)
    jsr(MOVETO_D_7F)
    jsr(DOT_HERE)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-o", "--out", default="cal.bin")
    args = parser.parse_args()

    header = bytearray()
    header += b"g GCE 1982\x80"
    header += (0xFD0D).to_bytes(2)          # BIOS music 1
    # A title block is required: an empty list hangs the BIOS before the
    # game ever runs (verified in simulation). Press any button to skip
    # the title music early.
    header += bytes([0xF8, 0x50, 0x20, 0xB8])   # height, width, y, x
    header += b"CALIBRATION\x80"
    header += b"\x00"                        # end of header

    entry = len(header)
    jsr(DP_TO_D0)
    loop = entry + len(code)

    jsr(WAIT_RECAL)
    # top reference line, full bright (length = 110 * $FF ~ 28000 units)
    line(120, -110, 0x7F, 0xFF, 0, 110)
    # intensity ladder: 14 lines, z = 8..112 step 8, top to bottom
    for i in range(14):
        line(96 - 14 * i, -110, 8 * (i + 1), 0xFF, 0, 110)
    # dwell pair: equal length (scale*delta), ~5x beam-speed difference
    line(-100, -110, 0x50, 0x18, 0, 0x7E)   # fast beam
    line(-100, 8, 0x50, 0x78, 0, 0x19)      # slow beam
    # dot row: dwell 1, 5, 20, 80. Low z so the dwell boost differentiates
    # instead of clamping every dot at full scale.
    for x, dwell in ((-90, 1), (-40, 5), (10, 20), (60, 80)):
        dot(-120, x, 0x20, dwell)
    emit(0x7E, loop >> 8, loop & 0xFF)      # JMP loop

    rom = bytes(header) + bytes(code)
    rom += b"\xff" * (4096 - len(rom))
    with open(args.out, "wb") as f:
        f.write(rom)
    print(f"{args.out}: {len(rom)} bytes, code {len(code)}, loop at ${loop:04x}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
