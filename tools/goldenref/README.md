# Golden-reference vector dumper

Captures the analytic line-segment list that the [vecx](https://github.com/jhawthorn/vecx)
emulator produces for each Vectrex frame. That list is the reference the FPGA
core's vector renderer is validated against.

vecx models the Vectrex beam the way we want the core to: it samples BLANK and
the integrator deltas in the same tick and emits explicit `(x0,y0)-(x1,y1)`
segments, with no delay compensation anywhere. See `alg_sstep()` in `vecx.c`.

## Building

vecx is not vendored here. Clone it alongside the other reference checkouts:

```
git clone https://github.com/jhawthorn/vecx refs/vecx
make -C tools/goldenref
```

Only `vecx.c` and `e6809.c` are compiled. The SDL frontend and audio backend
are replaced by a frame hook and stubs in `vecdump.c`, so there is no SDL
dependency. The Makefile rewrites one construct that modern GCC rejects
(`static einline` expanding to a duplicate `static`) into a local copy, leaving
`refs/vecx` untouched.

## Usage

```
./vecdump --bios ../../refs/vecx/rom.dat \
          --cart "../../refs/roms/Test rev4 (1982)(GCE)(proto).bin" \
          --skip 600 --frames 5 --pgm 540x720 --out /tmp/gold
```

Writes `frameNNNN.vec` (one segment per line: `x0 y0 x1 y1 color`, in vecx's
33000x41000 coordinate space) and optionally `frameNNNN.pgm`.

### On `--skip`

A "frame" is vecx's phosphor-decay period (1/30 s), not a display refresh. The
BIOS announcement sequence runs for roughly 350 of them and looks **identical
for every cartridge** — if two different ROMs produce byte-identical output,
the skip is too low, not the loader failing.

## Reference points in the Test Cartridge

The service manual (`refs/Vectrex-Service_Manual.pdf`, pages 20-23) documents
the rev 4 Test Cartridge's expected output with pass/fail criteria, which makes
it an acceptance suite rather than just test content:

| Skip | Pattern | What it validates |
|---|---|---|
| ~600 | Linearity grid | Pin cushion, barreling, keystone, size, centering |
| later | Integrator Off-Set | Diamond cross-bars, must align within one line width |
| later | Intensity | 17 lines; the 2nd-4th from top must be extinguished |
| later | Distortion 2 | 16 nested rectangles, equal spacing on every side |

The manual also states the checksum `B796` must appear.

Note that dashed and dotted output is often authentic: Vectrex text is drawn by
the VIA shift register toggling BLANK per bit, so broken-looking glyphs are
correct. The linearity grid, by contrast, is solid — use it, not text, to judge
whether the renderer is dropping segments.

## Comparing against the core

`sim/tb_vectrex.vhd` extracts the same kind of segment list from the FPGA core
running under ghdl, marking 1/30 s boundaries so the two line up frame by
frame. `compare.py` renders both into one raster and reports mutual coverage:

```
ghdl -r --std=08 -fsynopsys -frelaxed tb_vectrex \
     -gCART_FILE=cart.hex -gCART_MASK=4095 -gRUN_MS=500 -gDUMP_FILE=seg.txt

./compare.py --fpga seg.txt --frame 8 --golden gold/frame0000.vec --out cmp.png
```

Red is FPGA-only, green is golden-only, yellow is agreement.

Two things to line up before trusting a comparison:

**Frame numbering.** The testbench writes `# frame N` at `N/30` s, so the
segments following that marker belong to vecx frame index `N`. `vecdump --skip
K` makes its `frame0000.vec` the vecx frame at index `K`, so `--skip 8` pairs
with `--frame 8`.

**Axes are transposed.** `vectrex.vhd` derives `beam_v` from `lim_x` and
`beam_h` from `lim_y`, so the core's integrator X axis drives screen rows while
vecx's X drives columns. `compare.py` applies the swap; anything reading the
raw `.txt` dumps needs to do the same.

## Result: the core's beam geometry is correct

Measured on the Linearity Pattern, which is the right target because it is a
full-screen figure both sides draw identically, static, and free of the
shift-register text whose dot placement is timing-sensitive. Reached in
simulation with `run.sh ... 6000 seg_grid.txt 200`, and in vecx at `--skip
450`.

Agreement after calibration, by how many pixels of slack are allowed:

| tolerance | fpga within golden | golden within fpga |
|---|---|---|
| exact pixel | 48.0% | 48.2% |
| ±1 px | 89.9% | 91.4% |
| ±2 px | 100.0% | 100.0% |

So the two renderings agree everywhere to within 2 pixels on a 540x720 raster,
under 0.4%, with ~90% matching to within one. Given both sides rasterise
independently with different quantisation, that is as close as this method can
resolve. Distinct segment counts are 240 against 224, a 7% gap, far tighter
than the 26% seen on a text screen.

The calibration it needs, `x*1.0229 y*1.0954`, is the same on the title frame
(`x*1.0225 y*1.0963`), and their ratio is 1.071 against the 1.0732 predicted by
the two full-scale conventions above. The scale difference is therefore an
artefact of vecx's constants, not core geometry.

What this rules out is static geometric error: no pin cushion, barreling,
keystone, drift, or dropped vectors, which is exactly the list the service
manual says this pattern tests. It says nothing yet about the fast-moving beam,
dot brightness, or the resolution limit of the point-splatting renderer, and
those remain the open questions.
