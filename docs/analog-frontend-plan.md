# Analog frontend: implementation plan and progress

Working plan for executing `VECTREX_ANALOG_FRONTEND_MODEL.md` (2026-07-31),
staged so every step is verifiable against the ghdl simulation (which matches
silicon 100%, see docs/HANDOFF.md) and `tools/goldenref/`.

## Where the proposal stands against the branch (2026-08-06)

- **Stage 4 (VFB integration) is done** by other means: the beam taps feed
  `vectrex_video` and the vendored Asteroids `videodr0me_fb`, which brings its
  own source-domain crossing, async FIFO and position-change dedup. The
  renderer cannot backpressure the machine.
- **Frame segmentation is solved** by the CA2 marker (Wait_Recal holds
  `zero_integrator_n` low ~6.6 ms once per display pass; recentring pulses are
  25-276 us; threshold 1 ms; 40 ms watchdog). It is observational only, which
  is what the proposal demands of any marker.
- **The geometry premise is weaker than the proposal assumed**: goldenref
  showed geometry matches vecx within 2 px, so the whole-bus delay's harm is
  timing-sensitive software (Clean Sweep) and structure, not visible geometry.
- **Stage 3 (dwell/beam energy) targets the real remaining defects**: no beam
  cutoff, no dwell term across a 22x intensity range, second Intensity-test
  line still at peak 40.

## Stage 1 - per-path delays (this commit)

The whole-bus tap (`delay_buffer(94)` for PA, PB and CA2 as one word, CB2
undelayed) becomes six independently tapped paths, constants in
`rtl/vectrex_analog_pkg.vhd`:

| path | signal | constant | default |
|---|---|---|---|
| DAC data | PA[7:0] | `C_DELAY_DAC` | 94 |
| sample/hold enable | PB0 | `C_DELAY_SH` | 94 |
| mux select | PB2:1 | `C_DELAY_MUX` | 94 |
| RAMP | PB7 | `C_DELAY_RAMP` | 94 |
| ZERO | CA2 | `C_DELAY_ZERO` | 94 |
| BLANK | CB2 | `C_DELAY_BLANK` | 0 (undelayed) |

Defaults reproduce today's behavior exactly; the acceptance test is a
bit-identical segment list from `sim/run.sh` before and after. The point of
Stage 1 is that each path can now be tuned independently from measurement -
MAME schedules the same six effects separately (one shared 8.5 us value),
which is the structure this adopts with the delays kept per-path.

First experiment after the structure lands: `C_DELAY_BLANK` at ~102 ticks
(8.5 us, MAME's value) to see whether delaying blanking with the beam rather
than ahead of it changes the Test Cartridge or Clean Sweep. Each candidate is
one sim run diffed against goldenref before it earns a hardware build.

## Stage 2 - stateful analog (next)

Structure now, calibration later, defaults bit-identical:

- DAC first-order settle (`dac_alpha`, default 1 = instant).
- Sample/hold acquisition per held channel (`acquire_alpha`, default 1),
  droop deferred (constant 0) until measured.
- ZERO as calibrated discharge (`zero_alpha`, default instant).

All constants live in the same package. Every default-value build must stay
bit-identical in sim; that is what makes the structure safe to merge before
hardware measurements exist.

## Stage 3 - beam energy (after 1+2)

Dwell preservation and Z transfer feed the renderer's tone mapper; this is
where the Intensity-test defect gets fixed properly. Requires deciding how
dwell rides through the (position-deduping) rasterizer input - likely a
Z-weight accumulated per held position on the source side.

## Verification loop

1. `sim/run.sh <cart> 100` before/after - identical `seg.txt` for default
   constants (byte-diff).
2. `tools/goldenref/compare.py` against vecx for any non-default constant.
3. Hardware capture via the MiraBox loop (docs/HANDOFF.md) for anything that
   survives 1 and 2.
