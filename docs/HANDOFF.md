# Handoff & TODO

Branch `vector-renderer-rebuild`. Single evolving status document — keep
this short; everything durable lives in the reference docs:

- `docs/hardware-loop.md` — bench, capture, input injection, regression
  suites, simulation, and every operational trap.
- `docs/beam-model.md` — the beam energy model, the evidence behind its
  constants, and the BIOS/checksum finding.
- `docs/renderer-analysis.md` — the measurement record (geometry,
  splatter, timing) this work was redirected by.
- `docs/VECTREX_ANALOG_FRONTEND_MODEL.md` — analog frontend circuit
  analysis and model proposal.
- `rtl/videodr0me_fb/PROVENANCE.md` — vendoring record and local
  deviations.

## State

The rebuilt renderer (vendored `videodr0me_fb`) ships: HDMI good, timing
closed, 1080p internal raster, overlays with auto-load, OSD structured
after the Asteroids core, and the Stage-3 beam model (cutoff, dwell,
soft knee) verified against the real Test Cartridge on hardware. Both
regression suites are green: `tc_sweep.py` (Test Cartridge, on
hardware) and `game_sweep.py validate` (98/98, offline).

## TODO

1. **First hardware run of the game sweep** when the bench is free:
   `python3 tools/hwloop/game_sweep.py run --yes-touch-the-mister`.
   Doubles as threshold calibration; attracts that seed RNG from timers
   are the expected false-positive class.
2. **Beam constants wanting more references**: the 8-ticks/px dwell
   normalization, the knee shape, and the phosphor decay LUTs
   (inherited from Asteroids untouched) — a photodiode trace or PiTrex
   would settle all three.
3. **Stage 2 analog structure** (DAC settle, S&H droop, ZERO discharge
   as calibrated behaviors, defaults bit-identical): Malban's documented
   quirks (curved vectors, drift, wobble) are the acceptance tests.
4. **BIOS choice**: consider a factory/bug-fix BIOS option (checksum
   B796 vs 6293, authentic Mine Storm level-13 crash vs fixed).
5. **Presentation**: 720p hairline beading (likely profile spread
   settings — flagged to Videodr0me); overlay diffusion realism (the
   plastic sits ~1 cm off the phosphor); optional pincushion warp. A
   "Blend" persistence mode (two-frame hold) as the flicker-free choice
   for sub-50 Hz games like Pole Position.
6. **Housekeeping**: merge to master / release packaging decision.
