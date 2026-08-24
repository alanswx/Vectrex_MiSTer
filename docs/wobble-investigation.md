# Wobble Investigation Plan

Living checklist for isolating the visible frame-to-frame wobble. Update the
checkboxes, result tables, and findings log as evidence arrives. Do not tune
rounding or change production RTL until a test identifies the layer where
motion first appears.

## Current state

- Date opened: 2026-08-09
- Core: `Vectrex_dev.rbf`
- RBF SHA-256: `8f15b34780b2cca87f82a6704f5c315c6e161ee0ca4192c80b2d166c4220f2a4`
- MiSTer output: native 1280x720@60 (`video_mode=0`)
- Core render resolution: Match output (540x720 active image)
- Overlay: Off
- BIOS: Bug-fixed
- MiSTer scaler: `vscale_mode=0`, `vsync_adjust=0`, VRR Off
- Current status: CPU/VIA scanline-boundary timing fault fixed and verified in
  simulation and on hardware; geometric wobble is below 0.01 px globally.
  True two-frame `Blend=max(raw N, raw N-1)` is now implemented, simulation-
  verified, timing-clean at +0.141/+0.245 ns setup/hold, and deployed for a
  hardware pilot. The controlled test pattern has zero adjacent-frame
  brightness change at p95; physical-display confirmation is pending.

## Working hypotheses

Rank these again after each experiment. Use **supported**, **weakened**, or
**rejected** in the Status column.

| Rank | Hypothesis | Predicted signature | Status |
|---:|---|---|---|
| 1 | 59.8598 Hz source raster converted to fixed 60 Hz HDMI | Approximately 0.14018 Hz component; correction about every 7.13 s; framework stable while HDMI moves | Weakened: no 0.14018 Hz peak and `vsync_adjust=1` did not change the result |
| 2 | Alternating approximately 25 Hz completed redraws differ in intensity/coverage inside the framebuffer/phosphor path | Approximately 12.5 Hz brightness component at both 60 Hz and 50 Hz output; position essentially stable | Confirmed; true two-frame Blend removes steady-pattern redraw flicker |
| 3 | EOF/Wait_Recal marker or framebuffer promotion irregularity | Missing marker, 40 ms watchdog event, dropped frame, inconsistent buffer age, or incomplete frame | Weakened: calibration simulation finds clean long markers near 50 Hz and no missing-marker timeout signature; Test Cartridge path remains to verify |
| 4 | Monitor, scaler, or capture-device processing | Internal/framework image stable; motion appears only downstream | Weakened: the 12.5 Hz flicker is present in HDMI capture pixels |
| 5 | Fixed-point coordinate rounding alternates between adjacent pixels | Two discrete positions about one pixel apart, with identical intended geometry but changing mapped pixels | Rejected: mapping is deterministic; the upstream one-tick timing fault was identified and fixed |
| 6 | CPU/VIA enable gains a pulse at each 554-clock legacy scanline wrap | VIA/vector timing differs by one integration tick between redraws | Confirmed and fixed: a free-running divide-by-four enable makes repeated simulation redraws bit-identical |

## Known evidence

- [Renderer analysis](renderer-analysis.md#the-picture-wobbles-because-the-framebuffer-is-single-buffered)
  measured the old static-grid geometry at about 0.056 px row deviation and
  0.027 px column deviation. The old single-buffer redraw boundary was blamed
  for visible wobble and should be gone under buffer mode 0.
- The current coordinate mapping in `rtl/vectrex_video.sv` is deterministic
  fixed-point multiplication followed by truncation. Identical beam inputs
  should produce identical raster coordinates.
- At 720p the internal timing is
  `31,250,000 / (697 * 749) = 59.859822662 Hz`. Against fixed 60 Hz output,
  the beat is 0.140177338 Hz, or 7.134 seconds.
- MiSTer documents `vsync_adjust=0` as display-frequency matching with some
  stuttering, and `vsync_adjust=1` as core-frequency matching without
  stuttering:
  <https://github.com/MiSTer-devel/Scripts_MiSTer/blob/master/ini_settings.sh#L2327-L2334>
- MiSTer documents `vscale_mode=0` as potentially shimmering and integer mode
  1 as non-shimmering:
  <https://github.com/MiSTer-devel/Scripts_MiSTer/blob/master/ini_settings.sh#L2310-L2323>
- MAME derives Vectrex presentation cadence from VIA Timer 2 and notes that
  loss of synchronization causes flicker and that some strategies cause
  severe jerking:
  <https://github.com/mamedev/mame/blob/master/src/mame/miltonbradley/vectrex_v.cpp#L1106-L1194>
- Existing `hdmi_native720_20260809/*/rawframes` sequences contain only eight
  frames and stream-start transitions. They are too short to test a 7.13 s
  beat.

## Test rules

- [x] Use one controlled change per A/B pair.
- [x] Record the exact MiSTer INI and Vectrex config bytes for every capture.
- [x] Keep Overlay Off and the OSD closed during measurement.
- [x] Keep one capture stream open; discard stale/startup frames before saving.
- [ ] Capture raw 1280x720 YUYV at 60 fps, not MJPEG. The capture card
  delivers raw YUYV at only 10 fps; 60 fps requires MJPEG.
- [x] Save timestamps and frame hashes with every sequence.
- [ ] Analyze the unscaled 540x720 active crop as well as full HDMI frames.
- [x] Measure geometry and brightness independently.
- [x] Confirm the stimulus and core actually changed after every remote launch.

## Phase 1: Reproduce and classify

### Stimuli

- [x] Test Cartridge linearity grid: static geometry and tearing test.
- [ ] Calibration cartridge: fixed horizontal, vertical, diagonal, and dot test.
- [x] Cadence-stress title: Pole Position.
- [x] Record which title/screen most clearly matches the wobble seen by eye.
  The observer reported obvious flicker on the Test Cartridge grid and was
  unsure whether literal wobble remained.

### Baseline capture

- [x] Capture at least 60 continuous seconds under the current settings.
- [x] Preserve the full raw video or lossless frame sequence.
- [ ] Extract the active 540x720 area without resizing.
- [ ] Take a slower series of framework screenshots during the same static screen.
- [ ] If possible, record the physical monitor simultaneously for correlation.

Baseline metadata:

| Field | Value |
|---|---|
| Date/time | 2026-08-09, approximately 09:01 local |
| Stimulus and screen | Test rev4 linearity grid |
| ROM checksum | MD5 `8d66945eb9826d91ce27e07b2f8854f9` |
| RBF checksum | SHA-256 `8ee05a3bbd75e79e50dbb3fc33187b0a80bb349b1cba0b235153aec2f8eb071e` |
| Vectrex config bytes | `00 00 00 11 00 00 00 00 00 00 00 00 00 00 00 00` |
| MiSTer `video_mode` | `0`, 1280x720 output |
| `vsync_adjust` | `0` |
| `vscale_mode` | `0` |
| Persistence/profile | Profile / 80s Cruise Control; resolves to Short inter-frame decay at 720p |
| Capture format/rate | MJPEG at actual 60 fps plus lossless YUYV/FFV1 at device-limited 10 fps |
| Evidence directory | `wobble_baseline_20260809/` |
| Observer notes | Grid visibly flickers; literal wobble uncertain |

## Phase 2: Measure the motion

For every frame, track fixed grid intersections or vector ridges rather than
using a global threshold alone. Fit a global transform against a reference and
retain local residuals.

- [x] X translation per frame.
- [x] Y translation per frame.
- [x] X and Y scale per frame.
- [ ] Rotation per frame.
- [x] Per-line/local displacement after removing the global transform.
- [x] Total brightness and brightness of each tracked line.
- [x] Exact duplicate-frame pattern from hashes.
- [x] Autocorrelation and frequency spectrum of position and brightness.
- [ ] Histogram test for two states separated by approximately one pixel.
- [x] Row-dependent phase test for a sweeping tear boundary.

Initial acceptance targets:

- Static-position RMS below approximately 0.1 pixel.
- No bimodal one-pixel coordinate state.
- No coherent periodic displacement above approximately 0.2 pixel.
- Report brightness modulation separately from geometric movement.

Frequency fingerprints to check:

| Frequency/pattern | Interpretation |
|---|---|
| Approximately 0.14018 Hz / 7.13 s | 59.8598 Hz source versus fixed 60 Hz output |
| Approximately 10 Hz / 6:5 cadence | Approximately 50 Hz redraw presented near 60 Hz |
| 25 Hz / 40 ms event | Frame-marker watchdog or missed Wait_Recal marker |
| Exact every-other-frame state | Parity-dependent buffer or coordinate behavior |
| Phase changes progressively by row | Tearing or partial-frame presentation |
| Brightness changes without ridge motion | Persistence/frame-age behavior |

## Phase 3: No-build A/B matrix

Run in this order, returning to the baseline between tests.

| Test | A | B | Prediction | Result |
|---|---|---|---|---|
| Output synchronization | `vsync_adjust=0` | `vsync_adjust=1` after Main reboot | Seven-second correction disappears if output cadence is responsible | No material change; 12.49 Hz flicker and approximately 25 updates/s remain |
| Persistence | Profile/Short | Long override | Position remains fixed but apparent wobble changes if frame age is responsible | Long did not remove 12.5 Hz alternation; median redraw brightness delta was 1.50% Short versus 1.67% Long |
| Scaling | `vscale_mode=0` | Integer mode 1 | Downstream shimmer changes if scaler phase is responsible | Not run |
| Output cadence | 720p60 | 720p50 | Wobble spectrum follows display conversion if cadence-related | No improvement: median redraw brightness delta 1.24% at 60 Hz versus 1.25% at 50 Hz; same approximately 12.5 Hz pair |
| Beam energy model | Accurate | Raw | Separates dwell/cutoff effects from source beam timing | Raw worsened modulation: median redraw brightness delta 1.50% to 3.10%; X-position standard deviation 0.010 px to 0.021 px |
| Presentation chain | Raw/effects Off | Accepted profile | Separates geometry from halo/tone/persistence effects | Not run |

Layer interpretation:

| Observation | Likely layer |
|---|---|
| Framework and HDMI both move | Beam, rasterizer, EOF, or framebuffer |
| Framework stable; HDMI moves | MiSTer scaler, refresh conversion, or capture path |
| HDMI capture stable; physical screen moves | Monitor scaling, temporal dithering, or overdrive |
| Geometry stable; brightness pulses | Persistence/frame-age cadence |
| Different rows move at different phases | Tearing or incomplete-frame promotion |

## Phase 4: Simulation proof

Use GHDL waveform capture without changing production RTL. Align redraws on
the real long Wait_Recal/`frame_done` event, not the testbench's arbitrary
1/30-second reporting boundaries.

- [x] Capture several consecutive redraws of a static grid/calibration screen.
- [x] Compare `beam_x`, `beam_y`, `beam_on`, `beam_tick`, and `beam_zero_n`.
- [x] Compare production-equivalent mapped endpoints.
- [x] Compare emitted beam segment X/Y/Z/tick sequences.
- [x] Record the production-equivalent `frame_done`/`zero_run` threshold intervals.
- [ ] Record `marker_wd` directly and distinguish watchdog events.
- [ ] Record EOF FIFO push/pop events.
- [ ] Record draw-buffer and display-buffer indices.
- [ ] Record VBL swap/promote and raw-frame-drop events.
- [ ] Verify `height_q`, scale factors, and mode-ready stay constant.

Decision tree:

- Beam coordinates differ between nominally identical redraws: investigate
  CPU/VIA/integrator timing and Reset0Ref behavior.
- Beam coordinates match but mapped pixels differ: investigate coordinate
  mapping, clock-domain crossing, or rounding.
- Pixel streams match but completed frames differ: investigate EOF detection,
  FIFO ordering, and buffer ownership.
- Completed frames match but HDMI moves: investigate source/output cadence and
  downstream scaling.

## Phase 5: Hardware probes, only if needed

Use SignalTap only if simulation is stable but framework captures still move.
Trigger on `frame_done` and retain multiple complete redraw periods.

- [ ] Probe beam X/Y/on/tick/zero.
- [ ] Probe mapped pixel X/Y.
- [ ] Probe `frame_done`, zero-run threshold, and watchdog event.
- [ ] Probe EOF FIFO push/pop.
- [ ] Probe active draw and display buffers.
- [ ] Probe VBL swap request and buffer promotion.
- [ ] Probe dropped-frame indication.
- [ ] Probe `height_q` and mode-ready.

## Decision gates

- [x] Do not change rounding unless identical beam inputs produce different
  mapped pixels or a repeatable adjacent-pixel state is demonstrated.
- [ ] Do not change the frame marker unless missed Wait_Recal events, watchdog
  swaps, or incomplete-frame promotion are observed.
- [x] Do not add persistence/blending as a geometry fix; first prove whether
  the measured change is brightness-only.
- [ ] If `vsync_adjust=1` removes the wobble without changing internal frames,
  treat it as an output-cadence/configuration issue.
- [ ] If only the physical display moves, test the display path before changing
  the core.

## Findings log

Add one row for every experiment, including failed or inconclusive attempts.

| Date | Experiment | Configuration | Evidence | Finding | Hypothesis impact | Next action |
|---|---|---|---|---|---|---|
| 2026-08-09 | Plan created | Current 720p Match-output configuration | This document | No wobble-specific experiment run yet | All hypotheses open | Capture 60 s baseline grid |
| 2026-08-09 | Baseline grid capture | 720p, Match output, Profile/Short, `vsync_adjust=0` | `wobble_baseline_20260809/baseline_grid_720p60_mjpeg_65s.mkv`; `analysis_mjpeg60/` | 24.99 framebuffer changes/s held for mostly 2 or 3 HDMI frames; dominant 12.49 Hz brightness component; global X/Y standard deviation 0.0098/0.0057 px | Supports redraw/persistence flicker; weakens whole-image rounding wobble | Separate redraw-domain brightness from geometry |
| 2026-08-09 | Raw-pixel cross-check | Same baseline, lossless YUYV delivered at 10 fps | `baseline_grid_720p60_65s_ffv1.mkv`; `analysis_yuyv10/` | 12.5 Hz aliases to 2.5 Hz as predicted; X/Y standard deviation 0.0098/0.0082 px | Confirms MJPEG result is not compression-induced | Run persistence A/B |
| 2026-08-09 | Persistence A/B | Long override; all other core/global settings unchanged | `ab_persistence_long_grid_720p60_mjpeg_65s.mkv`; `analysis_persistence_long_mjpeg60/` | Dominant 12.5 Hz remains; median successive-redraw brightness delta 1.67% versus baseline 1.50% | Long decay is not a fix | Test output synchronization |
| 2026-08-09 | Output synchronization A/B | Baseline persistence; `vsync_adjust=1`; Main rebooted before capture | `ab_vsync_adjust1_after_reboot_grid_720p_mjpeg_65s.mkv`; `analysis_vsync_adjust1_after_reboot_mjpeg60/` | No material cadence, brightness, or geometry improvement | Weakens 59.86/60 beat hypothesis | Inspect redraw/frame composition in simulation |
| 2026-08-09 | Spatial phase test | Baseline 12.493 Hz component | `analysis_mjpeg60/spatial_phase_12p493hz.json` | Phase varies across both axes, consistent with vector draw order/frame age rather than a simple downward HDMI tear | Weakens simple scanout tearing | Align simulation on `frame_done` and compare consecutive completed frames |
| 2026-08-09 | Redraw-aligned calibration simulation | Compatibility analog path, 540x720 mapping, real 12,001-tick Wait_Recal threshold | `sim/build/redraw_cal_wobble.txt` | Stable passes contain 202 segments with identical Z; 128/202 segments vary by one beam tick; 117/202 segments occupy adjacent mapped endpoint pixels across ten redraws | Moves cause upstream of fixed-point rounding to source beam/integrator timing | Trace VIA/ramp/DAC transition phase around repeated vectors |
| 2026-08-09 | Beam Model A/B | Accurate versus Raw; otherwise baseline | `ab_beam_raw_grid_720p60_mjpeg_65s.mkv`; `analysis_beam_raw_mjpeg60/` | Raw doubled median redraw brightness modulation from 1.50% to 3.10% and increased X-position standard deviation from 0.010 px to 0.021 px | Accurate dwell/cutoff model damps rather than causes the symptom | Keep Accurate; investigate one-tick source timing |
| 2026-08-09 | CPU/VIA enable simulation A/B | Legacy scanline-derived phase versus free-running divide by four | `sim/build/redraw_cal_wobble.txt`; `sim/build/redraw_cal_stable_cpu.txt` | Legacy mode gained one CPU/VIA pulse at each 554-clock scanline wrap; 117/202 mapped endpoints alternated by one pixel. Stable mode produced ten identical redraw hashes and 0/202 changing endpoints | Confirms the geometric wobble source and validates the fix | Build and test on hardware |
| 2026-08-09 | Stable CPU/VIA enable hardware test | New RBF `fd171b...`, 720p60, baseline core settings | `fixed_stable_cpu_grid_720p60_mjpeg_65s.mkv`; `analysis_fixed_stable_cpu_mjpeg60/` | Observer reports wobble gone. Global X/Y standard deviation is 0.0089/0.0087 px. Median redraw brightness delta improved about 20%, from 1.54% to 1.24%, but approximately 12.5 Hz intensity flicker remains | Geometric fix supported; remaining symptom is downstream intensity/coverage alternation | Inspect alternating completed redraws in framebuffer/phosphor path |
| 2026-08-09 | Output cadence A/B after timing fix | 1280x720@60 versus 1280x720@50; all core settings unchanged | `ab_720p50_fixed_stable_cpu_grid_mjpeg_65s.mkv`; `analysis_720p50_fixed_stable_cpu_mjpeg/` | 50 Hz averaged two HDMI frames per source redraw, but median redraw brightness delta stayed 1.25% and the approximately 12.5 Hz pair remained | Rejects 60 Hz 2/3-frame hold cadence as the primary flicker source | Restore 720p60; trace completed-frame intensity alternation |

| 2026-08-09 | Inter-frame Off A/B | Cruise effects with only inter-frame processing disabled | `ab_custom_cruise_inter_off_grid_720p60_mjpeg_65s.mkv`; `analysis_custom_cruise_inter_off_mjpeg60/`; `pole_aligned_no_decay_720p60_mjpeg_65s.mkv` | Grid redraw median/p95 fell to 0.249%/0.852%, but dense Pole Position remained 9.22%/10.81% | Confirms the old decay compositor amplified intrinsic redraw differences but Off is incomplete on dense content | Implement provenance-correct two-frame max |
| 2026-08-09 | True Blend simulation and timing | Separate raw-history and clean composition-target ownership; output is `max(raw N, raw N-1)` | `sim/tb_vfb_blend_controller.sv`; `sim/tb_vfb_blend_compositor.sv`; RBF `8f15b347...` | Both focused tests pass. Seed 3 closes timing at +0.141 ns setup and +0.245 ns hold; failed seeds were not deployed | Validates ownership, exact pixel rule, and physical feasibility | Run controlled hardware A/B |
| 2026-08-09 | True Blend hardware pilot | 720p60, Match output, Cruise/Profile (mode 1 now Blend), Overlay Off | `blend_grid_720p60_mjpeg_65s.mkv`; `analysis_blend_grid_mjpeg60/`; `pole_aligned_blend_720p60_mjpeg_65s.mkv`; `analysis_pole_aligned_blend/` | HDMI locked and geometry was clean. Controlled test sequence had only 57 changed adjacent pairs in 3,601 comparisons and all-frame p95 brightness delta 0%; prior no-decay changed about 1,500 pairs. Pole stayed live and clean, but its non-phase-locked global brightness statistic is not a reliable A/B verdict | Strongly supports Blend as the steady-content flicker fix; no evidence of freeze or geometry regression | Obtain physical-display verdict, then run a small game regression before making Blend the accepted default |
| 2026-08-09 | Blend freeze RGB diagnosis | Instrumented RBF `8c64c1e7...`; Narzod; one-second unchanged-display-index latch | Framework capture first showed normal content, then encoded compositor IDLE, DDR arbiter IDLE, metadata ready, composed display, no draw buffer, no requests, and DDR not busy | The freeze is an ownership starvation terminal state, not a DDR or compositor hang | Confirms the controller can become idle with DISPLAY + RAW_HISTORY + queued DRAWN buffers and no CLEAN/DIRTY path forward | Permit saturation recovery while the compositor is idle |
| 2026-08-09 | Blend saturation recovery | Recovery drop no longer requires `compose_active`; focused terminal-state regression | `sim/tb_vfb_blend_controller_saturation.sv`; diagnostic RBF `33c55155...`; Narzod 90 s; Pole gameplay 60 s | New regression and all prior focused tests pass. Diagnostic latch never fired; Narzod final pair changed 68,022 pixels and Pole final pair changed 62,758 pixels | Confirms the ownership-starvation fix on hardware | Remove diagnostics and validate the clean binary |
| 2026-08-09 | Clean Blend recovery candidate | 720p60, Match output, Cruise/Profile Blend, Overlay Off | RBF SHA-256 `39688bd6b34e3791c39d2c9d43211636b94586d943aa8732fe8eb69eb2b16b04`; setup/hold +0.018/+0.252 ns; Pole gameplay 60 s | Pole remained live with no video stop; final capture pair changed 182,585 pixels | Freeze/black-frame regression is fixed in the clean timing-qualified build | Record physical-display flicker/strobe verdict and run a small representative catalog regression |
| 2026-08-10 | Observer verdict on clean Blend recovery | Physical display; Pole Position; 720p Match output; Blend; Overlay Off | Direct observer report | Wobble is gone and the image is much better. A small flash remains, and the background occasionally drops out | Confirms the geometric and major flicker improvements; Blend is not yet accepted because intermittent content loss remains | Correlate dropout events with raw-frame drops/compositor saturation before tuning persistence |
| 2026-08-10 | Six-buffer scheduling candidate | One additional DDR framebuffer; oldest-completed raw scheduling retained; 720p Match output; Blend; Overlay Off | RBF SHA-256 `71c9bda3d07817939f2698a515203c368dea7d5a0f322765edfd5809b307928e`; setup/hold +0.264/+0.201 ns; `sim/tb_vfb_blend_controller_stress.sv`; `wobble_baseline_20260810/pole_six_buffer_scheduler_720p60_mjpeg_65s.mkv` | Under the same overloaded simulation, five buffers completed 119 compositions with 179 raw drops; six completed 139 with 159 drops. Seven gave no useful gain (140/158). All focused ownership, saturation, compositor, layout, DDR-stall, and fairness tests pass. Pole Position and Narzod each remained live for 60 s. The continuous Pole capture contains 3,900 frames; after startup its longest exact hold was 4 frames/66.7 ms, and its strongest 100 ms local global-luma dip was 6.5%, with no abrupt whole-output loss captured | Six buffers reduce scheduling pressure and remove about one-sixth of the simulated composition bubbles without the cost of an unproductive seventh buffer. This run did not reproduce or correlate the observer's rare background dropout | Obtain a physical-display verdict on this exact RBF; if dropout remains, expose non-invasive raw-drop/saturation event telemetry and correlate it to capture |

## Current next action

- [x] The original wobble was traced to the scanline-derived CPU/VIA enable,
  fixed with a free-running divider, and verified in simulation and hardware.
- [x] Treat the remaining symptom as intensity flicker and isolate the old
  compositor as an amplifier of completed-frame alternation.
- [x] Implement and simulation-test provenance-correct two-frame Blend using a
  separate target buffer.
- [x] Diagnose the Blend video freeze as ownership starvation and add a focused
  terminal-state regression.
- [x] Fix idle saturation recovery and verify Narzod and Pole Position remain
  live on both the diagnostic and clean timing-qualified builds.
- [x] Record the observer's physical-display verdict: wobble gone and flicker
  much improved, with occasional background dropout and a small residual flash.
- [x] Reduce Blend scheduling pressure with a sixth framebuffer. The overloaded
  stress test improves from 119 compositions/179 drops to 139/159; a seventh
  buffer gives no material improvement. Focused simulations, timing, Pole
  Position, Narzod, and a continuous 65-second HDMI capture pass.
- [ ] Determine whether each visible dropout coincides with
  `raw_frame_dropped` or another compositor-saturation event.
- [ ] Run a small representative game regression before accepting Blend as
  default.
