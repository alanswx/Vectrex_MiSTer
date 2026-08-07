# Accuracy & presentation plan

How to make the core render more like a real Vectrex, and look better doing
it, with every change justified by a reference rather than by taste. Written
2026-08-07. This is a plan, not a work log; execution state belongs in
`docs/HANDOFF.md` and `docs/analog-frontend-plan.md`.

"Accurate" and "looks better" are different axes and sometimes fight (a real
Vectrex flickers *more* than our renderer at low game rates). The rule this
plan follows: model the machine accurately, then make presentation choices -
persistence, halo, bloom - explicit, user-selectable, and each anchored to
something measured.

---

## 1. What we can already trust

- **The ghdl simulation is the silicon.** `sim/run.sh` matches hardware
  100% (docs/HANDOFF.md), so any measurement made in simulation stands for
  the real core. This is the lever everything else multiplies.
- **vecx golden reference** (`tools/goldenref/`): analytic segment lists,
  geometry agreement within 2px. Good for geometry, useless for brightness
  (vecx models no intensity physics).
- **MAME's analog model** (`refs/emulators/NOTES.md`): ANALOG_DELAY
  scheduling, one-shot ZERO recentering, zero-ref DAC summed into both
  axes. A second, independent opinion on analog behavior.
- **The service manual** (refs/): pages 20-23 give pass/fail criteria for
  Linearity and Intensity patterns. The Intensity test is our one known
  objective failure (lines 3-4 visible, should be extinguished).
- **The closed hardware loop**: MGL launch + MS2109 capture at 1080p.
  Every claim below ends with "verified by capture" or it didn't happen.

## 2. Reference material to acquire

### 2a. Real-hardware captures (ground truth, highest value)

Nothing else substitutes. Three routes, in order of preference:

1. **A real Vectrex + camera, shot to a protocol.** Own, borrow, or a
   community member's machine (Vector Gaming forum, VFU, or Videodr0me
   himself - he clearly has reference material behind his profiles).
   Protocol per game, so footage is comparable across machines and with
   our captures:
   - dark room, tripod, manual exposure/focus/white balance locked;
     note camera model and settings in a sidecar file
   - 60 fps normal pass **and** a high-frame-rate pass (240 fps phone
     slow-mo minimum) - the slow-mo pass is what separates real flicker
     from camera-beat flicker, which is the trap Videodr0me called out
   - stills at base ISO for geometry/halo (long exposure integrates a
     full frame; good for line-width and halo cross-sections)
   - each game: attract + 30s gameplay, with and without its overlay
   - always include the Test Cartridge patterns on the same machine, so
     per-machine drift (they all drift; the manual documents calibration)
     can be normalized out
2. **PiTrex as a programmable reference instrument.** A Raspberry Pi on
   the cartridge port that halts the 6809 and drives the real analog
   stage and CRT directly. That means we can draw *chosen* test figures -
   single segments at controlled rates, dwell ladders, intensity ramps,
   the exact stimuli Stage 2/3 calibration wants - on a real tube and
   film them. A Vectrex plus a ~$40 board turns "find footage of the
   right scene" into "generate the right scene".
3. **Photodiode + oscilloscope phosphor measurement.** A photodiode taped
   to the tube over a repeating bright dot, scope on the diode: P31 decay
   curve directly, quantitatively (P31 is nominally ~1ms to 10%, good
   exponential; labguysworld's CRT phosphor research PDF has curves).
   This is the calibration source for the renderer's inter/intra-frame
   decay LUTs, which today are inherited from Asteroids untouched.

### 2b. Curated YouTube corpus (broad, qualitative)

Real-hardware footage exists on YouTube for most of the GCE catalog.
Build an index file (`refs/reference-captures/INDEX.md`, gitignored like
the rest of refs/): per game, URL + timestamp + what it is good for.
Selection criteria: visible CRT (not emulator), overlay identified,
preferably a static camera. Uses and limits:

- **good for**: overlay appearance on the tube (tint, ambient, how much
  vectors color through), relative brightness of scene elements, halo
  and bloom character, what flickers on real hardware and how badly
- **not usable for**: absolute timing or flicker depth (camera beat),
  color calibration (auto WB), geometry (lens + angle)

Also mine the written record - it encodes what footage can't:
- Malban's analog documentation (vide.malban.de: "How Vectors are
  drawn", the Drift/Wobble/Shiftreg tags, the analog pages) - the most
  complete catalog of real-machine quirks: integrator drift, curved
  vectors from RC settling, shift-register text dashing, per-game
  oddities. Each quirk is a testable prediction for our analog model.
- Jed Margolin's "The Secret Life of Vector Generators" + "XY Monitors"
  (jmargolin.com) - Atari-side, but the CRT/deflection/spot physics
  transfers.
- The Test Cartridge + manual criteria we already use.

### 2c. Emulator cross-references

- **vecx** - already integrated (goldenref).
- **MAME** - worth extending goldenref to dump MAME's segment stream the
  way we dump vecx's; where vecx and MAME disagree, a real-hardware
  capture referees. Its ANALOG_DELAY/recentering model is the main
  alternative hypothesis to ours.
- **VIDE/Vecxi (Malban)** - the emulator written by the person who
  documented the analog quirks; its display code is a reference for
  which quirks matter perceptually. Add to refs/emulators with notes.
- **openFPGA-Vectrex** (Analogue Pocket port of this core's ancestor) -
  downstream relative; worth a look at what they changed, and a future
  beneficiary of this work.

## 3. Comparison infrastructure (build once, use everywhere)

- **Reference corpus layout**: `refs/reference-captures/<game>/` holding
  real-hardware clips/stills + sidecar metadata (machine, camera,
  settings, source URL or "shot by us"), alongside same-game captures
  from the core (`mister-<date>-<build>.mkv`). Gitignored; INDEX.md
  catalogs it.
- **A/B capture automation**: we already launch any game + overlay via
  MGL and capture 1080p. Wrap that into a batch: given a game list,
  produce a standard capture set per build (attract 15s, title still,
  overlay on/off). Cheap regression suite for "did this change help".
- **Metrics** (each already prototyped by hand this week; make them
  repeatable): geometry segment-diff vs goldenref; brightness
  histograms and per-element peak tracking; flicker depth/spectrum from
  60fps capture (per-region dip analysis, as done for Pole Position);
  line cross-sections for width/halo (as done for the 540 vs 1080
  comparison). Plus one new one: phosphor decay fit from consecutive
  unique frames, to compare against the photodiode curve.
- **Side-by-side review sheet**: an HTML contact sheet per build - real
  capture, our capture, difference metrics - so "looks better" gets
  judged on evidence, by humans, quickly.

## 4. Accuracy workstreams, ranked by expected payoff

1. **Beam energy / dwell (analog-frontend Stage 3).** The one measured
   objective failure (Intensity test lines 3-4) plus the largest known
   modeling gap: brightness ignores dwell across a 22x range. Fixes the
   test cartridge and makes bright dots/slow strokes render right.
   Calibrate the cutoff and transfer curve against PiTrex/real-machine
   intensity ramps.
2. **Analog frontend Stage 2** (DAC settle, S&H droop, ZERO discharge as
   calibrated behaviors, defaults bit-identical). This is where Malban's
   documented quirks - curved vectors, drift, wobble - become
   reproducible instead of coincidental. Verify each claimed quirk
   appears for the games he documents it in.
3. **Phosphor calibration.** Replace inherited decay LUTs with curves
   fit to photodiode measurement; expose the existing Persistence
   override as the deliberate deviation from measured truth (smoother
   than real, for sub-50Hz games). Consider a "Blend" persistence mode
   (two-frame hold, +1 rendered frame latency) as the flicker-free
   choice for heavy games like Pole Position.
4. **Beam spot model.** Real spots defocus with intensity and toward
   screen edges; segment starts carry a settling dot; text from the
   shift register dashes. Some of this exists via halo/bloom profiles -
   anchor spot size vs intensity to the long-exposure stills rather
   than to taste.
5. **Presentation polish with references in hand**: the 1080-to-720
   hairline beading (stroke width vs downscale ratio - likely the
   profile spread settings, flagged to Videodr0me); overlay realism
   (the plastic sits ~1cm off the phosphor: slight diffusion of the
   ambient art, and vectors illuminate the overlay from behind -
   compare against overlay-on real footage); optional tube-geometry
   warp (real tubes pincushion slightly; overlays were drawn for that).
6. **Geometry** is last because it already matches vecx within 2px -
   revisit only if real-hardware stills disagree with both.

## 5. Milestones

- **M1 - corpus exists**: YouTube INDEX.md for the GCE catalog (28
  titles + key homebrew), refs layout, batch A/B capture script,
  metrics runnable on demand. No RTL changes.
- **M2 - ground truth**: real-machine session shot to protocol (or
  PiTrex acquired and generating test figures), photodiode decay curve
  in hand. Publish the measurement record next to the overlays' one.
- **M3 - Stage 3 lands**: Intensity test passes all five criteria;
  dwell-driven brightness verified against intensity-ramp footage.
- **M4 - Stage 2 lands**: at least two of Malban's documented quirks
  reproduce on our core in the games he names, without per-game hacks.
- **M5 - calibrated presentation**: phosphor LUTs from measurement,
  spot model from stills, beading fixed; side-by-side sheet shows our
  capture vs real capture for ten titles and the differences are
  deliberate, documented choices.

## 6. Sources found in the 2026-08-07 survey

- PiTrex: gtoal/pitrex on GitHub, ombertech on Tindie, retrorgb.com
  coverage, vide.malban.de/pitrex
- Malban's VIDE + analog documentation: vide.malban.de ("How Vectors
  are drawn", Drift/Wobble/Shiftreg tags)
- Jed Margolin, "The Secret Life of Vector Generators" / "XY Monitors":
  jmargolin.com/vgens/
- CRT phosphor data: labguysworld.com/crt_phosphor_research.pdf (P31)
- Chris Salomon's vector display notes: playvectrex.com/designit/
  chrissalo/vectordisplay.htm; vectrex.com "Understanding the Vector
  Display"
- Scopetrex (Vectrex on an oscilloscope), Trammell Hudson's vector
  display projects: trmm.net/Vectrex
- openFPGA-Vectrex: github.com/obsidian-dot-dev/openFPGA-Vectrex
- Blur Busters CRT beam simulator (presentation-side prior art):
  github.com/blurbusters/crt-beam-simulator
