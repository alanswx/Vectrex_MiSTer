# Beam energy model: what it is and the evidence behind it

Reference for the Stage-3 beam model in `rtl/vectrex_video.sv` and the
measurements that set its constants. Nothing here is a plan; open
calibration items are listed in `docs/HANDOFF.md`.

## The model

The raw DAC intensity `z` passes through, in order:

1. **Grid cutoff** — `BEAM_CUTOFF = 28`: z below it emits nothing
   (unless the OSD "Beam Model: Raw" bypass is on).
2. **Dwell accumulation** — ticks are counted per held beam position;
   emission happens one position late so a position's full dwell is
   known when it emits.
3. **Dwell boost** — brightness scales with `sqrt(ticks / 8)` via an
   octave lookup table: slow strokes and dots deposit more energy, as
   on a real tube.
4. **Soft knee** — above energy 100 the response compresses as
   `100 + 27*(E-100)/(E-100+127)`, capped at 125. Ordering is
   preserved all the way up; nothing hard-clips.
5. The tone mapper, whose low-end lift is display adaptation (see gun
   physics below), then the phosphor/halo/bloom pipeline.

## Evidence

**Cutoff = 28.** Three independent sources bracket it:

- The service manual's Intensity screen criterion (p. 19): ladder lines
  2-4 (z = 8, 16, 24) must be extinguished, line 5 visible. Passes on
  the real Test Cartridge on hardware.
- A static scan of 162 catalog ROMs for `Intensity_a` immediates: the
  commercial-era floor is $1E/$1F (30/31); exactly one ROM (a 1999
  homebrew) uses a nonzero value below 28. Designers who tested on real
  tubes treated ~30 as the dimmest useful intensity. Together with the
  criterion, the cutoff is bracketed to (24, 30].
- The Z-axis circuit (service manual p. 30): the Z input is AC-coupled
  (C409) with a DC-restore clamp (D402), the amplifier (Q503) drives
  the CRT cathode, and G1 bias comes from the BRIGHTNESS pot (R509).
  The cutoff position in DAC counts *is* the pot setting, and the
  manual's Intensity screen is that pot's calibration procedure — so a
  fixed cutoff models a correctly adjusted machine.

**Gun physics and the tone mapper.** Cathode drive gives beam current
roughly proportional to V^2.5-3 above cutoff, so z=30 content is ~1%
luminance on a real tube — visible on a 300:1 CRT in a dark room,
crushed on an 8-bit LCD pipeline. The tone mapper's low-end lift is
display adaptation of an accurate model, not error.

**Dwell law.** The calibration cartridge
(`tools/testcart/make_calcart.py`) draws equal-length lines at equal z
with a 5x beam-speed difference; on hardware they measure 2.2x apart in
brightness — sqrt(5), as the model predicts. Its dot row orders by
dwell time.

**Soft knee, not a clamp.** Real-tube footage (an SVM System Test
intensity ladder on a GCE machine, serial 0058095, shot with no camera
clipping; `refs/reference-captures/`) shows a working tube grades its
ladder smoothly and monotonically to the very top. An earlier hard
ceiling flattened the top of the ladder; the knee replaced it and the
real Test Cartridge's INTENSITY screen now grades ~135→218 on capture.

**The shimmer on the INTENSITY screen is authentic.** A/B over the OSD
switch: Raw shimmers *more* (per-line std 7.5-25.5) than Accurate
(0-20). It is the test screen's own analog redraw variation.

**Measurement note.** A single screenshot is not a stable brightness
metric for multi-line scenes: intra-frame phosphor decay means each
line's brightness depends on its age since the beam drew it when the
frame snapped. Use the per-line max over several captures
(`tools/hwloop/tc_sweep.py` does).

## BIOS variants and the Test Cartridge checksum

The Test Cartridge checksums the BIOS along with itself:

- factory BIOS (crc32 `ba13fb57`, vecx's `rom.dat`) → **B796**, the
  value printed in the service manual;
- the Mine Storm bug-fix BIOS this core ships (crc32 `105afd6a`,
  `rtl/bios_rom.vhd`; NOP-patched jumps into fix code placed in
  previously empty space) → **6293**.

Verified by running vecx with the BIOS extracted from `bios_rom.vhd`:
it renders 6293 exactly. The cart-space fill (zeros/FF/mirror beyond
the 4 KB ROM) does not enter the checksum. So 6293 on the core is
correct-as-shipped, and the checksum screen doubles as a BIOS integrity
check. A factory-BIOS option would restore B796 — and the authentic
Mine Storm level-13 crash.

## Related analysis

- `docs/renderer-analysis.md` — the measurement record that redirected
  this work (geometry was already correct; brightness and buffering
  were the real defects).
- `docs/VECTREX_ANALOG_FRONTEND_MODEL.md` — component-level analysis of
  the analog vector generator (integrators, S&H, delays) and the model
  it proposes; per-path delay structure exists in
  `rtl/vectrex_analog_pkg.vhd` with identity defaults.
