# What is actually wrong with the vector renderer

Measurements against the vecx golden reference and the Quartus fitter, made
before changing any of the beam logic. Several of them contradict the premises
the rewrite was originally justified by, so they are recorded here rather than
left in commit messages.

Reproduce with `sim/run.sh`, `tools/goldenref/vecdump`, `tools/goldenref/compare.py`
and `tools/goldenref/beamspeed.py`.

Status notes in **[resolved: ...]** brackets were added after the fact; the
measurements stand, but every open problem this document ends on has since
been closed. `docs/HANDOFF.md` has the current state.

## Verified on hardware

The whole chain agrees. Deploying the core to a MiSTer, loading the Test
Cartridge and capturing its Linearity Pattern with mrext's screenshot API
gives, against the same pattern from simulation and from vecx:

    hardware vs simulation           100.0% / 100.0%   (raw)
    simulation vs vecx, calibrated   100.0% / 100.0%
    hardware vs vecx, uncalibrated    41.9% /  39.8%

Simulation reproduces silicon exactly, within the 2px tolerance this method
resolves, so every measurement below that was made in simulation stands for the
real core too. The gap to vecx is entirely the scale factor documented under
geometry, not error on either side.

## Geometry is correct

On the Linearity Pattern — static, full-screen, and free of the shift-register
text whose dot placement is timing sensitive — the core and vecx agree
everywhere to within 2 pixels on a 540x720 raster, and to within 1 pixel over
about 90% of lit pixels. Distinct segment counts are 240 against 224.

That covers exactly what the service manual (pages 20-23) says the pattern
tests: pin cushion, barreling, keystone, size, centering. None of them are
wrong. **The delay hacks are not distorting a static image.**

The scale difference that remains, `x*1.0229 y*1.0954`, is not core error. The
two full-scale conventions have different aspect ratios:

    core   max_x / max_y         = 180000 / 135000 = 1.3333   (exactly 4:3)
    vecx   ALG_MAX_Y / ALG_MAX_X =  41000 /  33000 = 1.2424

whose ratio, 1.0732, accounts for the measured 1.071 to three figures. The
core's 1.3333 matches its 540x720 framebuffer; vecx's constants are the
approximate ones.

## The splatter oversamples, it does not drop vectors

`rtl/vectrex.vhd` writes at most one framebuffer pixel per `clken_12` tick, at
the beam's current position. If the beam advanced more than a pixel per tick,
lines would come out dashed. It does not, anywhere measured:

| content | segments | mean advance | worst | dashed |
|---|---|---|---|---|
| Test Cartridge title | 1 038 | 0.159 px/tick | 0.249 | 0 |
| Mine Storm title | 52 373 | 0.147 px/tick | 0.249 | 0 |
| Mine Storm, past start | 65 556 | 0.148 px/tick | 0.249 | 0 |
| Linearity grid | 57 838 | 0.189 px/tick | 0.256 | 0 |
| Mine Storm playfield | 26 677 | 0.023 px/tick | 0.176 | 0 |

Roughly 5 to 6 writes land on each pixel. That is the opposite of the failure
mode assumed at the outset, and it explains `dac_ob` (rtl/vectrex.vhd:490): it
adds 5 per repeated write and saturates, standing in for beam dwell time
because nothing else models it.

The worst case barely moves across content whose vectors differ by a factor of
twenty in length — 11.9px over 48 ticks on one screen, 261.6px over 1023 on
another — because it is not a property of the content. Port A is 8 bits, sign
extended to 9 (rtl/vectrex.vhd:440), so `ref_level` and `dac_y` are both in
[-128, 127] and the per-tick integrator step in

    integrator_x <= integrator_x + (ref_level - dac_y)      -- :469

cannot exceed 255 units. That is a hard ceiling on beam velocity:

| framebuffer | worst px/tick | |
|---|---|---|
| 540x720 (current) | 0.51 | solid, 2x margin |
| 1080p 3:4 | 0.77 | solid |
| 1440p 3:4 | 1.02 | marginal |
| 4K 3:4 | 1.53 | dashed |

Measured content peaks at 0.256, half the ceiling, so games use at most about
half the available DAC swing per step. **Point splatting is sufficient by
construction through 1080p**; only past roughly 1440p does sampling itself
force an analytic rasteriser.

Dashes visible in text are the VIA shift register toggling BLANK per bit, which
is authentic. The linearity grid, drawn solid, is the pattern to judge dropped
segments against.

## Resolution is limited by block RAM, not by sampling

This is the constraint that actually forces the rewrite.

    M10K blocks              491 / 553   (89%)
    Block memory bits      3.87 / 5.66 Mbit
    Framebuffer alone      3.11 Mbit, about 80% of block memory in use

The four scan buffers at 540x720x8 already consume most of the device's memory.
A 3:4 framebuffer at 1080p needs 7.00 Mbit and at 1440p 12.44 Mbit, against
5.66 Mbit total on the chip. Neither fits at any sampling rate, with or without
the rest of the core.

So higher resolution requires moving the framebuffer off-chip, which is what
Videodr0me's `videodr0me_fb` does with DDR3 plus SDRAM and a tile cache.
Removing the overlay path (which owned the SDRAM) was the prerequisite.

Port from Major Havoc (2026-07-31), not Asteroids. It is the newest of his
cores and its framebuffer has moved on considerably: 4295 changed lines across
every file plus a new `vfb_layout_pkg.sv`, with the largest edits in
`vfb_halo_wide` (958), `vfb_sdram_delay` (461), `vfb_readout` (458) and
`vfb_rle_encoder` (444).

Note which constraint binds first. Memory rules out 1080p outright, while
sampling stays adequate there and only fails past about 1440p. So the reason to
move off-chip is capacity, and an analytic rasteriser is worth having for
quality — stroke width, antialiasing, dwell-correct brightness — rather than
because vectors are being dropped.

## The picture wobbles because the framebuffer is single buffered

Reported from hardware: the image is "very wobbly". It is not beam instability.
Across 66 frames of the same static linearity pattern the drawn geometry barely
moves at all:

    centre row   sd 0.056 px, range 0.15 px
    centre col   sd 0.027 px, range 0.06 px
    height       sd 0.084 px

The cause is that there is one framebuffer and both sides use it at once. The
phase machine at `rtl/vectrex.vhd:520` interleaves scanout reads and persistence
writes on phases 00 and 10 with beam writes on 01 and 11, into the same four
banks. Nothing is double buffered.

Meanwhile the two sides run at unrelated rates. The video scanner is
554 clocks by 722 lines at 24 MHz, which is 60.002 Hz, while the Vectrex
program redraws at roughly 50 Hz, whatever its own display loop happens to
take. So the scanner is always showing an image that is partly the current
redraw and partly the previous one, with the boundary sweeping at the ~10 Hz
difference. The rate is program dependent, so the artefact drifts rather than
sitting still, which is what makes it read as wobble rather than as a clean
rolling bar.

Persistence makes it worse: the decay pass at `:528` subtracts as the scanner
walks the frame, so brightness is being reduced progressively down the screen
while the beam is independently redrawing it.

`vfb_top` takes `BUFFER_MODE` and a `FRAME_DONE` marker precisely so that
scanout reads a completed frame. This is a fourth reason for the port, and the
only one a user can see without measuring anything.

## Brightness ignores dwell time

This is the first thing measurement has found actually wrong.

On a CRT a pixel's brightness is beam current multiplied by the time the beam
spends on it. The core writes, at `rtl/vectrex.vhd:583`:

    pix_fx <= dac_z(6 downto 0) & dac_z(6)   when overburn = '0'
         else X"FF"                          when (dac_z + dac_ob) > 255
         else dac_z + dac_ob;

and the framebuffer write is an overwrite, not an accumulate. So with
`overburn = '0'`, which is the menu default, brightness is the commanded Z
scaled and nothing else. A pixel written four times and a pixel written sixteen
times come out identical.

Dwell is not a small effect, and it is largest exactly where the picture is
sparsest. A game screen has few vectors, so the beam lingers:

    linearity grid          min  3.9   median 7.4   max 15.6
    Mine Storm playfield    min  5.7   median 9.5   max 84.1

Across the two that is a 22x range in how long the beam sits on a pixel, all
of it rendered at the same value. Gameplay is where the error is worst, not
the test patterns.

### The core fails the manual's Intensity test

Page 21 gives a criterion: 17 evenly spaced horizontal lines, of which the
2nd, 3rd and 4th from the top must be extinguished and the 5th, which sits on
the word INTENSITY, must be visible. Captured from hardware:

    line   peak   width    expected        actual
      1     191    76%     visible         visible
      2      16     0%     extinguished    extinguished
      3      32    73%     extinguished    VISIBLE
      4      48    73%     extinguished    VISIBLE
      5     255    73%     visible         visible

Lines 3 and 4 should not be on screen at all. This is a second brightness
defect, separate from dwell: a real tube has a cutoff, below which grid voltage
produces no beam current and the vector simply does not appear. The core has
none. `pix_fx` at `:583` maps `dac_z` linearly with

    dac_z(6 downto 0) & dac_z(6)

so every non-zero Z produces a lit pixel, and intensities the hardware would
swallow get drawn. Note the failure is asymmetric: line 2 does vanish, so the
cutoff is not simply absent, it is set far too low.

`dac_ob` is the only thing that models dwell at all, and only partially:

  * it is gated behind the Overburn option, off by default
  * it accumulates a flat +5 per tick while `beam_v`/`beam_h` are unchanged
    (`:505`), so it is additive where the physics is multiplicative
  * it saturates at 255, clipping exactly the bright vectors it exists for
  * it resets the moment the beam moves a pixel, so it captures a stationary
    dot's dwell but not a slow-moving stroke's

This is what `vfb_tone_mapper.sv` addresses in Videodr0me's cores, and it is a
better argument for the renderer work than anything about dropped vectors.

## HDMI is broken on this branch, and not by the video path

**[resolved: two stacked faults, the qsf fitter settings and an unwired
generate branch: the qsf fitter settings were placement-breaking HDMI,
and the gen_new_video branch had no video wiring (fixed in c6e943e).]**

Every build from this branch shows "input not supported" on HDMI, while
unmodified master works. The video path has been ruled out: restoring the
original arrangement wholesale, the core's own framebuffer, video_freak,
CLK_VIDEO off clk_sys at 24 MHz and syncs straight from vectrex.vhd, renders a
correct picture matching master's output levels and still fails HDMI.

Major Havoc, built from refs/ on the same Quartus and device, works. So it is
neither the machine nor videodr0me_fb.

What remains untested is the non-video changes: the qsf fitter settings, the
SDC clock groups, pll_vfb existing, the FB_* tie-offs, and vectrex.vhd's
register initialisers; the culprits were the qsf fitter settings and
the unwired generate branch, and the other suspects are innocent.

## Port status

videodr0me_fb is instantiated and renders on hardware. The Test Cartridge's
linearity pattern comes through complete, and against the old core on the same
pattern:

    new renderer vs old core   99.9% / 100.0%

so geometry survives the port. Block memory drops from 3.87 Mbit to 2.26 and
RAM blocks from 491 to 304 despite gaining the whole CRT pipeline, which is the
1080p ceiling lifted.

Settled by measurement:

  * the frame marker heuristic works. Detecting the BIOS's long blanked
    recalibration produces presentable frames rather than a black screen,
    which was the most likely thing to be wrong
  * Z must go through vfb_tone_mapper. Feeding dac_z straight in gives a very
    dim picture
  * COLOR is {Rhi, Rlo, G, B}, so the 4'b1111 taken from Asteroids weights red
    double. Presentation now selects CHANNEL_BW, and lit pixels measure
    [55.4, 55.4, 55.4]

Not settled: **[both since resolved - timing was clock-domain constraints
(closed to ~0), and the wobble was the single-buffered framebuffer, gone
under BUFFER_MODE 0.]**

  * timing does not close. -10.6ns on the 125 MHz clock, every worst path from
    the HPS f2sdram bridge into vfb_ddr_arbiter. Both ends are the same clock,
    so it is a long route out of a hard block rather than a crossing. Matching
    Major Havoc's fitter settings moved it 0.07ns. Worth raising with
    Videodr0me, who runs the same bridge into the same arbiter at 125 MHz
  * whether the wobble is fixed. Across three captures of a static screen the
    lines are stable, 20191/20221/19619 lit pixels above a mid threshold, but
    brightness and halo vary. Some of that is phosphor decay doing its job.
    Stills cannot separate the two; this needs someone watching the screen

## The frame marker is wrong

**[resolved: the marker now derives from CA2/Wait_Recal exactly as proposed
below, and BUFFER_MODE 0 renders without tearing - rtl/vectrex_video.sv.]**

The Vectrex has no frame signal, so vectrex_video guesses one: it watches for
an unusually long stretch with the beam blanked, on the theory that the BIOS
recalibrates once per display pass. That guess is wrong, and there is now a
clean experiment proving it.

vfb_top's BUFFER_MODE selects when the framebuffer swaps: 0 is end-of-frame
plus vertical blank, 1 is vertical blank only, 2 is end-of-frame only. Mode 1
ignores FRAME_DONE entirely.

  mode 1, ignoring FRAME_DONE   renders correctly, but tears
  mode 0, honouring FRAME_DONE  mostly black with fragments of the pattern

So the marker is not landing on real frame boundaries. Mode 1 is what ships for
now, which is why the picture tears against the beam.

Deriving it properly needs a signal the beam actually produces. The BIOS's
Wait_Recal pulls CA2 low to zero the integrators for an extended period once
per pass, so a long assertion of zero_integrator_n is a better candidate than a
long blank. That signal is not currently on the dbg_* taps.

## Timing was a constraint bug

The core reported -12.5ns setup slack and 18.45MHz against a 24MHz clock.
`beam_h`/`beam_v` are written and consumed entirely inside the `clken_12`
domain, which pulses every second clock, so the path has two periods. The SDC
said so with `-from {emu|vectrex|limited_*}`, but synthesis infers a DSP for the
`lim_*` multiply and launches from its output register, named
`lim_y[n]~N_OTERMnnn`. The exception never matched.

Constraining the destinations instead: +3.978ns, TNS 0.000.

## What remains unexamined

**[since measured on hardware: the Intensity test fails on lines 3 and 4,
recorded above; the fix is the Stage 3 dwell work in
docs/beam-model.md.]**

Not yet measured:

- the Intensity test on page 21, which gives a pass/fail criterion (17 lines,
  the 2nd to 4th from the top must be extinguished). This would say whether the
  Z *scaling* is right, separately from the dwell problem above, which is
  already established from the RTL.

  Not reached in simulation, and abandoned there on cost. Driving the Test
  Cartridge menu means simulated button presses, and the ROM advances several
  stages per press regardless of how short the press is: a 15ms tap, well
  inside one poll interval, still lands on the terminal KEYS screen. Each
  attempt is around three hours of wall clock, so iterating on it is poor value
  against what it adds.

  It is trivial on real hardware. Load the Test Cartridge on a MiSTer, press
  button 3 to the Intensity screen, and look at which of the 17 lines are lit.
  That is the sensible way to close this one.
- phosphor persistence, currently a blind whole-buffer decrement
  (rtl/vectrex.vhd:528) with no per-pixel timing
