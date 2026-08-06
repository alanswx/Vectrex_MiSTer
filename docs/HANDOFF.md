# Handoff: vector renderer rebuild

Branch `vector-renderer-rebuild`, 53 commits, pushed to origin. Everything
below is committed; the working tree is clean apart from Quartus rewriting
`Vectrex.qsf` on every build, which should be reverted rather than committed.

**The one blocking problem: HDMI shows "input not supported" on every build
from this branch. It works on unmodified `master`.** Everything else works.

---

## Start here: the HDMI bisect

This is the only thing standing between the branch and something usable, and
it has been narrowed a long way. Do not start over.

### What is known

| build | HDMI | VGA |
|---|---|---|
| `master`, the released core | works | out of sync |
| Major Havoc, built from `refs/`, same Quartus and device | works | not checked |
| this branch, new renderer | fails | works |
| this branch, `DIAG_SIMPLE`, colour bars, no framebuffer at all | fails | shows bars |
| this branch, `LEGACY_VIDEO`, original video path restored wholesale | fails | not checked |

The last row is the important one. With `LEGACY_VIDEO = 1` in `Vectrex.sv`,
the core's own framebuffer is back, `video_freak` is back, `CLK_VIDEO` comes
off `clk_sys` at 24 MHz, and the syncs come straight from `vectrex.vhd` — the
exact arrangement `master` uses. The picture renders correctly and matches
`master`'s output levels. **HDMI still fails.**

So the video path is not the cause. Something else on this branch is.

### What is left to test

Non-video changes, in the order worth trying. Each is one build with
`LEGACY_VIDEO = 1` still set, reverting one thing:

1. **`Vectrex.qsf` fitter settings.** `SEED` went 1 to 2, and
   `PHYSICAL_SYNTHESIS_EFFORT EXTRA` and `REMOVE_REDUNDANT_LOGIC_CELLS ON`
   were added to match Major Havoc. These change placement globally. The
   HDMI output path (`d[n] -> hdmi_out_d[n]` inside `sys_top`) was failing
   timing by 8.5ns at one point purely from congestion, so placement
   demonstrably matters here. Revert to `master`'s settings first.

2. **`Vectrex.sdc` clock groups.** A `set_clock_groups -asynchronous`
   covering core, framebuffer, HPS, audio, HDMI and board clocks was added.
   Declaring the HDMI PLL asynchronous to everything tells the fitter it need
   not time those crossings, which could let it place HDMI logic badly.
   Revert to `master`'s SDC and see.

3. **`pll_vfb` existing at all.** A second PLL is instantiated even when
   unused. Under `DIAG_SIMPLE` it gets pruned, and HDMI still failed, so this
   is unlikely — but it has not been tested with `LEGACY_VIDEO`.

4. **`FB_*` tie-offs.** `master` leaves `FB_EN` and friends floating; this
   branch drives them to zero. Should be harmless or better, but untested.

5. **`rtl/vectrex.vhd` register initialisers and the `INTERNAL_FB` generic.**
   Synthesis-neutral in principle, and the initialisers are needed for
   simulation.

If reverting all five with `LEGACY_VIDEO = 1` still fails, the fault is
something not yet on this list, and the next move is a mechanical bisect:
`git checkout master`, confirm HDMI, then re-apply commits in order.

### Traps that cost real time

- **`Vectrex.sv` has mixed CRLF and LF line endings.** Three separate edits
  silently matched nothing because the pattern used bare `\n`. One of them
  left `CLK_VIDEO` undriven, which produced "no video on either output" and
  was misread as a hardware symptom for a full round trip. Always match
  `\r?\n`, and always grep the file afterwards to confirm the edit landed.
- **mrext's screenshot API returns 200 without taking a screenshot.** Compare
  the newest `modified` timestamp before and after the POST. A stale capture
  was presented as a fresh result once.
- **The MiSTer is shared.** Other people load cores on it. Check
  `/tmp/CORENAME` before trusting any capture; two results were from
  `zektor` and `shangon`.
- **`CLK_VIDEO` cannot be muxed in fabric.** It feeds `hdmi_clk_sw` and
  `vga_clk_sw`, hardware Clock Select Blocks that Quartus requires be driven
  straight from a PLL output or clock pin. Selection has to be a build-time
  constant.

---

## Hardware loop

The MiSTer at `192.168.1.75` takes ssh with the existing key, and mrext's
Remote service is on port 8182.

```bash
# build
quartus_sh --flow compile Vectrex

# deploy, and check the md5 matches on both ends
scp output_files/Vectrex.rbf root@192.168.1.75:/media/fat/_Console/Vectrex_dev.rbf

# launch with a cartridge
curl -X POST -H 'Content-Type: application/json' \
  -d '{"path":"/media/fat/games/VECTREX/Applications/Test rev4 (1982)(GCE)(proto).bin"}' \
  http://192.168.1.75:8182/api/games/launch

# screenshot: POST, then verify the timestamp advanced, then fetch
curl -X POST http://192.168.1.75:8182/api/screenshots
curl -s http://192.168.1.75:8182/api/screenshots     # newest entry has .path
curl -o shot.png "http://192.168.1.75:8182/api/screenshots/<url-encoded path>"
```

Screenshots capture the core's video **before** the output stages, so a clean
screenshot does not mean HDMI or VGA work. That distinction is what finally
localised the HDMI fault to the output side.

`POST /api/controls/keyboard/{name}` accepts only MiSTer system keys: `osd`,
`up`, `down`, `left`, `right`, `reset`, `confirm`, `back`, `menu`, `user`,
`screenshot`, `volume_up`. It cannot press Vectrex buttons, so walking the
Test Cartridge menu needs a human. Be careful: `reset` and `osd` act on the
running core immediately.

---

## What works and is worth keeping

### Renderer

`videodr0me_fb` is vendored from Major Havoc and renders correctly on
hardware. Set `LEGACY_VIDEO = 0` in `Vectrex.sv` and `DIAG_SIMPLE = 0` in
`rtl/vectrex_video.sv` to get it back.

- geometry matches the old core **99.9% / 100.0%**
- block memory drops **3.87 Mbit to 2.26**, RAM blocks **491 to 304**, which
  is the 1080p ceiling lifted
- halo, bloom and phosphor visibly working
- fixes one of the two lines the manual's Intensity test says should be
  extinguished

### Timing

Closed from **-44.9ns to -0.025ns**. Every violation was a clock-domain
declaration, never slow logic, and every one showed the same tell: a path one
or two logic levels deep missing by nanoseconds.

- `pll_audio` at 40.682ns was being timed against the renderer's 8ns clock
- reset crossed into 125 MHz unsynchronised
- the board oscillator reached the DDR bridge reset

Building Major Havoc as a control is what cracked it: the identical path
closed there at +0.926ns, proving the fault was local.

Also fixed a real pre-existing bug: `master`'s multicycle exception on
`limited_*` never matched, because synthesis infers a DSP for the `lim_*`
multiply and launches from its output register. The core reported -12.5ns and
18.45 MHz against a 24 MHz clock for years. Constraining the destinations
instead gives +3.978ns.

### Test infrastructure

- `tools/goldenref/` — builds `vecdump`, which captures vecx's per-frame
  segment lists. `compare.py` diffs them against the core; `beamspeed.py`
  measures how far the beam moves per framebuffer write.
- `sim/` — runs the core under ghdl. `run.sh` handles everything including a
  workaround for Ubuntu's broken ghdl-llvm soname. Roughly 0.7s of wall clock
  per emulated millisecond.
- **Simulation matches silicon 100%**, verified against a hardware capture of
  the Linearity Pattern. Every measurement made in simulation therefore has
  hardware behind it.

### What measurement established

Recorded in full in `docs/renderer-analysis.md`. The short version is that
the premises this work started from were mostly wrong:

- **geometry is correct** — matches vecx to within 2px, so the delay hacks are
  not distorting anything
- **the splatter oversamples**, roughly 6 writes per pixel, and the DAC width
  caps beam speed at 0.51 px/tick, so nothing is being dropped
- **the real defects are brightness and buffering**: no beam cutoff (proven
  against the manual on hardware), no dwell term across a 22x range, and a
  single-buffered framebuffer tearing 60.002 Hz scanout against a ~50 Hz
  redraw

---

## Known broken or unfinished

1. **HDMI.** Above.
2. **Frame marker.** `vectrex_video`'s long-blank heuristic does not find real
   frame boundaries. Proven: `BUFFER_MODE = 0` honours `FRAME_DONE` and gives
   a mostly black screen; mode 1 ignores it and renders. Currently on mode 1,
   which is why the picture tears. The fix is to derive the marker from the
   BIOS's `Wait_Recal`, which pulls CA2 low to zero the integrators once per
   display pass. `zero_integrator_n` needs adding to the `dbg_*` taps.
3. **Orientation option does nothing** under the new renderer. It reaches
   `vectrex.vhd`, which swaps `lim_x`/`lim_y`, but the taps read the
   integrators upstream of that swap. Rotation has to move into
   `vectrex_video`.
4. **Scale option** was lost with `video_freak` and is restored only under
   `LEGACY_VIDEO`.
5. **OSD controls** for halo, bloom and phosphor are hardcoded to
   `PROFILE_TYPICAL`. They should be menu entries.
6. **Second Intensity line** still renders at peak 40 when it should be
   extinguished. A different `tone_mapping` value may fix it.

---

## Overlays, when the renderer is working

Asteroids gained a `vfb_overlay.sv` on 2026-08-05, newer than the Major Havoc
version currently vendored here. It loads VART artwork from **ROM index 2**
into DDRAM and blends it **after** CRT presentation, which is right for a
plastic overlay on the tube.

Index 2 is exactly where the old OVR loading lived, so the menu slot is free:
a `"F2,VART"` entry feeding `ioctl_index 2` is all the plumbing needed, and no
MRA is required since `vfb_overlay` takes the ioctl signals directly.

`refs/Arcade-Asteroids_MiSTer/artwork/build_artwork.py` converts indexed PNGs
into a VART container, one image per output resolution. The 95 overlays in
`overlays/` are all 540x720, which is already the native 720p raster; the other
planes need scaling to 810x1080, 360x480 and 180x240. Artwork does not follow
vector orientation, so portrait art is correct for a portrait raster.

Taking the newer Asteroids framebuffer means about 4,900 changed lines against
the vendored Major Havoc one. `rtl/videodr0me_fb/PROVENANCE.md` asks that local
changes stay in the wiring rather than in his files, which is what makes that
upgrade a copy rather than a merge. His framebuffer has moved substantially
twice in eleven days.

---

## Reference material

`refs/` is gitignored and holds: the Asteroids, Major Havoc, Tempest, Star Wars
and Battlezone cores; the vecx emulator; the Vectrex service manual as a PDF;
and a curated set of test ROMs including the rev 4 Test Cartridge, whose
expected output the manual documents with pass/fail criteria on pages 20-23.
