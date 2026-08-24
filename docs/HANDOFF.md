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
soft knee) verified against the real Test Cartridge on hardware. The
`tc_sweep.py` Test Cartridge regression is green on hardware. The historical
correlation-only `game_sweep.py` run reported 98/98 offline and on hardware
(structural captures require Overlay Off), but that result is no longer an
acceptance result: the analog pilot proved correlation can hide major geometry
errors. On 2026-08-08 the replacement gate ran the full catalog on
compatibility RBF SHA-256 `b5e1f80d51fa6f2530ff94c6350bdaac5cf9df26c03b3de9b29bd7f07c92894c`:
65/98 cleared coverage automatically and 33 were flagged for review. All
588 captures (six per title) were then inspected directly and found clean, for
98/98 visual acceptance; three blank hands-off titles were skipped. Evidence is in
`game_sweep_compat_pilot_20260808/` and
`game_sweep_compat_full_20260808/`. The build fit and assembled with zero
errors; its Vectrex clock has +3.560 ns setup slack, while the 125 MHz
framebuffer domain has small placement-sensitive setup/hold misses of
-0.153/-0.078 ns. The current dev RBF, SHA-256
`8ee05a3bbd75e79e50dbb3fc33187b0a80bb349b1cba0b235153aec2f8eb071e`,
adds an OSD-selectable Bug-fixed/Factory BIOS and automatically resets when the
selection changes. Bug-fixed remains the default. Quartus inferred both 8192x8
ROMs, fit at 48% block memory, and completed 0-error fit/assembly; core setup
slack is +3.576 ns and the 125 MHz framebuffer setup/hold slacks are
-0.096/+0.170 ns. A post-deploy Clean Sweep/Star Castle pilot passed the strict
gate and all 12 images were directly reviewed clean. Full Test Cartridge hardware
sweeps then proved Bug-fixed -> 6293 and Factory -> B796; all other diagnostic
criteria passed. The saved bench state was restored to Bug-fixed with Overlay Off.
Evidence is in `game_sweep_bios_pilot_20260808/`,
`tc_sweep_bios_fixed_20260808/`, and `tc_sweep_bios_factory_20260808/`.

Native 720p presentation is now hardware-verified. With MiSTer
`video_mode=0`, leaving the core at its 1080p render target produced the same
periodic vertical-line beading in both framework and raw 1280x720 HDMI
captures, proving it was upstream of the MiraBox. Switching the existing OSD
control to `Render Res: Match output` changed the active framework image from
589x720 to 540x720 and made the vectors continuous. The Clean Sweep/Star
Castle pilot was directly clean, followed by a 98-title full catalog run: the
old 1080p-reference coverage gate accepted 46/98, but direct review of all 588
captures found correct geometry, no clipping or displaced copies, and no
recurring beading. Three blank hands-off titles remained skipped. There is no
separate anti-shimmer implementation; Match output is the effective 720p fix.
The bench is intentionally left at `video_mode=0`, Bug-fixed BIOS, Overlay Off,
and Match output (`VECTREX.CFG` starts `00 00 00 11`). The prior global config
is backed up as `/media/fat/MiSTer.ini.pre_vectrex_720p_20260809`. Evidence is
in `hdmi_native720_20260809/`, `game_sweep_native720_match_pilot_20260809/`,
and `game_sweep_native720_match_full_20260809/`.

The 2026-08-09 wobble/flicker investigation then separated two faults. A
scanline-derived CPU/VIA enable caused one-tick endpoint alternation; the
free-running divider fix removed the geometric wobble on hardware. The
remaining approximately 12.5 Hz intensity flicker came from completed redraw
differences amplified by the old persistence compositor. A provenance-correct
two-frame `Blend=max(raw N, raw N-1)` now uses a retained raw-history buffer
and separate clean target. Controlled hardware capture reduced steady-pattern
adjacent-frame brightness change to 0% at p95.

A later dense-content freeze was diagnosed with an RGB state build: compositor
and DDR arbiter were both idle, DDR was not busy, metadata was ready, the
display buffer was composed, and no draw buffer or request remained. The
controller could saturate with no CLEAN target while its recovery drop was
incorrectly gated by `compose_active`. Idle saturation recovery is now allowed,
with regression `sim/tb_vfb_blend_controller_saturation.sv`. The clean deployed
RBF was SHA-256 `39688bd6b34e3791c39d2c9d43211636b94586d943aa8732fe8eb69eb2b16b04`;
it closed timing at +0.018/+0.252 ns setup/hold. Narzod ran 90 seconds and Pole
Position gameplay ran 60 seconds on the diagnostic fix; that clean binary then
passed another 60-second Pole gameplay smoke test with live sequential frames.
Observer verdict on 2026-08-10: the wobble is gone and the result is much
better, but the background occasionally drops out and a small flash remains.

The current deployed candidate adds a sixth framebuffer and generic completion
ordering. Under the identical overloaded scheduler simulation it improves from
119 compositions/179 raw drops with five buffers to 139/159 with six; seven
buffers are the knee's far side at 140/158. Focused ownership, saturation,
exact-max compositor, layout, DDR long-stall, and DDR fairness tests pass. RBF
SHA-256 is `71c9bda3d07817939f2698a515203c368dea7d5a0f322765edfd5809b307928e`;
setup/hold slack is +0.264/+0.201 ns. Pole Position and Narzod each remained
live for 60 seconds. A 65-second 720p60 Pole capture delivered 3,900 frames;
after startup its longest exact hold was 66.7 ms and no abrupt whole-output
loss was captured. The bench is left on Pole Position with Cruise/Profile
Blend and Overlay Off. Obtain the observer's physical verdict on this exact
candidate; do not accept Blend as final until any remaining dropout is
correlated with raw-drop/saturation telemetry.

The Stage-2 analog
frontend structure is implemented behind the bit-identical default
`ANALOG_MODEL=0`. Its stateful coefficients are now bounded from the service
schematic and component datasheets; focused tests, enabled-model GHDL
synthesis, and a 50 ms Clean Sweep trace pass. A full enabled Quartus build
also fits, but its 2026-08-08 hardware pilot was rejected: Clean Sweep and
Star Castle showed gross scale/offset errors and displaced copies. The old
correlation-only sweep falsely passed both; `game_sweep.py` now also requires
bidirectional whole-image coverage, and the full sweep was stopped. A retrospective
check of the 12 titles captured before the abort makes the limitation explicit:
correlation alone accepted all 12 failed-model sets, while coverage 0.48 flagged
all 12 for review. The same conservative threshold automatically accepts only
4 of those 12 stable-build sets, so a coverage failure is a review result, not
proof of a renderer failure. The
optional offline
`TRACE_CURVE_TOL=16` representation reduces that trace from 12,172 to 958
segments; production rasterization already consumes per-tick coordinates and
has no segment-queue bottleneck.

## TODO

1. **Beam constants wanting more references**: the 8-ticks/px dwell
   normalization and the numerical knee shape. Public real-tube footage
   proves the upper ladder stays ordered but cannot identify a unique
   curve through phone gamma/exposure. The inherited decay LUTs are now
   classified as LCD presentation adaptation, not physical P4 constants;
   see `docs/beam-model.md`.
2. **Stage 2 is shelved pending physical evidence**: the experimental Q8
   frontend remains in `rtl/vectrex_analog_frontend.vhd`, disabled by the
   byte-identical `ANALOG_MODEL=0` default. Whole-core coefficient controls now
   permit live/delayed inputs, DAC settle, S&H acquisition/droop, and ZERO
   sweeps without RTL edits. MAME and vecx both use step events; a MAME-style
   delayed-step configuration is byte-identical to compatibility for the 50 ms
   Clean Sweep trace (SHA-256 `3b931453e524543ee1835b354fccb5b266650c8b094ce0095bb95ecdc5b01f8c`),
   while the gradual RC defaults are hardware-rejected. Emulator and document
   evidence therefore supports the existing compatibility path, not coefficient
   tuning. Do not resume enabled-model hardware work or expose an OSD switch
   without real-board measurements or another independent physical reference.
3. **Presentation**: native 720p is accepted with `Render Res: Match output`;
   no dedicated anti-shimmer filter exists or is currently needed for that
   mode. True two-frame max is implemented as Blend with retained raw history
   and a separate composition target; focused ownership and pixel tests pass.
   Controlled capture shows 0% adjacent-frame brightness change at p95 on
   steady content. The dense-content video stop was ownership starvation; idle
   saturation recovery and its focused regression are now present. The clean
   timing-qualified RBF is deployed, and Narzod plus Pole Position remained live
   through extended hardware tests.
   The physical-display verdict is a major improvement with wobble gone, but
   occasional background dropout and a small residual flash remained on the
   five-buffer build. The six-buffer candidate reduces overloaded-simulation
   drops from 179 to 159 and passes focused simulation plus Pole/Narzod hardware
   tests; its physical-display verdict is pending. Next, correlate any remaining
   visible event with `raw_frame_dropped` and compositor saturation, then run a
   representative game regression before accepting Blend as default.
   Lower-priority ideas are overlay diffusion realism and optional pincushion
   warp. Continue updating
   `docs/wobble-investigation.md`.
4. **Housekeeping**: merge to master / release packaging decision.
