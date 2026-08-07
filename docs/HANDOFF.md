# Handoff: vector renderer rebuild

Branch `vector-renderer-rebuild`, pushed to origin. The working tree is clean
apart from Quartus rewriting `Vectrex.qsf` on every build, which should be
reverted rather than committed (`git checkout -- Vectrex.qsf`).

**HDMI is fixed (2026-08-06).** The new renderer drives HDMI at
540x720 44.86KHz into the 720p scaler, verified on hardware by capture card:
BIOS boot screen and Minestorm gameplay. `LEGACY_VIDEO = 0` and
`DIAG_SIMPLE = 0` are the shipping configuration. The HDMI clock closes
positive; the 125 MHz renderer clock hovers just negative (see Known broken).

---

## How HDMI was fixed

It was two independent faults stacked, which is why the bisect kept pointing
away from the video path:

1. **The `Vectrex.qsf` fitter settings** (suspect #1 in the old bisect list).
   `SEED 2`, `PHYSICAL_SYNTHESIS_EFFORT EXTRA` and
   `REMOVE_REDUNDANT_LOGIC_CELLS ON` broke HDMI sync even with
   `LEGACY_VIDEO = 1` restoring the original video path wholesale. Reverting
   `Vectrex.qsf` to `master`'s settings restored sync, proven by capture.
   The `d[n] -> hdmi_out_d[n]` path in `sys_top` is placement-sensitive.
   Beware: this also means an unlucky future seed could regress HDMI; if it
   ever fails again after an innocent change, suspect placement first.

2. **The `gen_new_video` generate branch had no video wiring.** When the
   legacy path was restored behind `LEGACY_VIDEO`, the else-branch kept only
   the aspect-ratio assigns; `CLK_VIDEO`, `CE_PIXEL`, `VGA_R/G/B`, `VGA_HS/VS`
   were all left unconnected on the `vectrex_video` instance. The framework's
   info overlay showed the tell exactly: core video `0x0 0.00KHz 0.0Hz`
   against a live `1280x720 74.25MHz 60.0Hz` output — HDMI synced, OSD
   worked, screen black. Fixed by routing the outputs through `vfb_*` wires
   as they were before the restructure (commit c6e943e).

Suspects 2-5 from the old list (`Vectrex.sdc` clock groups, `pll_vfb`
existing, `FB_*` tie-offs, `vectrex.vhd` initialisers) were never individually
tested and are all still in place — they are innocent.

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

### HDMI capture card (closes the loop that screenshots cannot)

The MiSTer's HDMI passes through a MiraBox capture box (MS2109,
`534d:2109`) on its way to the monitor, and the box's USB goes to this
machine: video at the `/dev/video*` node whose udev `ID_MODEL` is
`MiraBox_Capture` (currently `/dev/video4`; `/dev/video0/2` are a webcam),
audio at the ALSA card named `MS2109`. The MiSTer's output mode is
1920x1080@60 (`video_mode=8` in MiSTer.ini, changed 2026-08-07; the prior
720p file is MiSTer.ini.bak_claude) - capture at `-video_size 1920x1080`,
which the MS2109 delivers at 30 fps MJPEG (60 fps needs 1280x720). This sees the real HDMI output —
scaler, OSD, info overlay and all — so it can distinguish "syncs" from
"input not supported" without a human at the monitor.

```bash
# one frame (~1s); a no-signal chip yields a pure black frame, mean -91 dB audio
ffmpeg -f v4l2 -input_format mjpeg -video_size 1280x720 -i /dev/video4 \
  -frames:v 2 -update 1 -y shot.png

# capture N seconds after a core load: frames:v 30 per second
# per-frame brightness, to tell a black screen from a dead one
ffmpeg -f v4l2 -input_format mjpeg -video_size 1280x720 -i /dev/video4 \
  -frames:v 90 -vf "signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-" \
  -f null - 2>/dev/null | grep YAVG
```

Traps, each of which cost time on 2026-08-06:

- **Zoom (or any app) holding the device wedges it silently**: opens
  succeed, frames arrive, but they are the no-signal black frame even with
  a live input. Quit the app, then `USBDEVFS_RESET` ioctl on
  `/dev/bus/usb/<bus>/<dev>` (python, no sudo needed) and recapture.
- The chip latches no-signal at power-up; after changing the input, reset it.
- The Altera USB Blaster's cable is easy to mistake for the capture box's;
  a replug that does not change the MiraBox's `lsusb` device number
  replugged something else.
- `load_core` via ssh: `echo load_core /path/to.rbf > /dev/MiSTer_cmd`.
  The framework's info overlay in the top-left of a capture reads
  `<core video>` over `<output>` — core-side `0x0 0.00KHz 0.0Hz` with a
  live output line means the core's video outputs are not driving the
  framework.

### Build and deploy

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

`videodr0me_fb` is vendored from Asteroids (ab07109, 2026-08-05; see
`rtl/videodr0me_fb/PROVENANCE.md` for the local deviations) and renders
correctly on hardware, now over HDMI as well. `LEGACY_VIDEO = 0` in `Vectrex.sv` and
`DIAG_SIMPLE = 0` in `rtl/vectrex_video.sv` is the shipping configuration;
setting them to 1 restores the original video path for diagnosis.

- the internal raster is 810x1080 by default regardless of output mode
  ("Render Res" in the OSD switches back to matching the output); the
  scaler downsamples, which reads much cleaner at 720p/480p. Enabling
  this exposed a 32-bit overflow in the beam scale factors (1080 << 22)
  that crushed the long axis 19x - fixed with 34-bit intermediates in
  `vectrex_video.sv`
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

(Items about the frame marker, orientation, scale and the CRT-effects menu
from earlier revisions of this list are all fixed and described above.)

1. **Beam-energy model (Stage 3) landed 2026-08-07**: grid cutoff at
   dac_z 28 plus dwell-scaled intensity (sqrt(ticks-per-position / 8),
   octave LUT, one-position emission latency) in `vectrex_video.sv`,
   with an OSD A/B switch (Beam Model: Accurate/Raw). Measured with
   `tools/testcart`'s calibration cartridge on hardware: z=8/16/24
   lines extinguished (the manual's Intensity criterion now passes by
   construction; the old "second Intensity line at peak 40" defect is
   gone), equal-length lines drawn 5x apart in beam speed measure
   2.2x apart in brightness (sqrt(5) predicted), line endpoints bloom
   like real hardware. Confirmed on the real Test
   Cartridge's Intensity screen (human button press): lines 2-4
   extinguished, line 5 visible - the manual's criterion passes. The
   screen's shimmer was A/B'd via the OSD switch: Raw shimmers MORE
   (per-line std 7.5-25.5 vs 0-20 Accurate), so it is the test
   screen's own analog redraw variation, not the beam model - real
   machines shimmer here too. Remaining calibration, wants
   real-Vectrex reference footage (accuracy-plan M2): the
   8-ticks/pixel normalization and cutoff value; and the dwell boost
   clamps the slow-drawn Intensity lines at the ceiling, flattening
   the ladder gradation Raw shows (61-227 ramp) - whether a real tube
   keeps that gradation decides the boost knee. Fast BIOS text
   renders ~0.7x.
2. **The OSD's video settings are structured after Videodr0me's Asteroids
   core** (2026-08-07): a "Video Profiles & Effects" page (profile selector
   with per-profile hidden overrides, full Custom 1/2 settings, Persistence,
   Overlay controls) and a "Video Timing & Geometry" page. The status word
   is 128-bit; custom-profile bits match Asteroids' positions except Off's
   Dot Scale (status[63:61] here). h-flag visibility comes from
   status_menumask (bit 7 Off, 8 Touch, 9 Typical, A Overdriven,
   B flashing, D/E Custom 1/2, 5/6 bloom/halo curve gating). Don't put
   commas inside "-,text;" lines - the OSD truncates at the comma.
3. **The calibration cartridge** (`tools/testcart/make_calcart.py`)
   boots straight into an intensity ladder, a fast/slow dwell pair and
   a dwell dot row - no button presses, so it runs over the remote
   loop, in ghdl, and in vecx (`tools/goldenref/vecdump` runs it in a
   second, which is how its bugs were found). Traps that cost time:
   an empty title list in the cart header hangs the BIOS; Moveto_d at
   scale $FF rails the integrators - use Moveto_d_7F ($F2FC), whose
   mapping is displacement = coord x 127 (measured against vecx).
4. **Renderer clock slack drifts negative build to build**: the verified
   2026-08-06 builds closed at -0.018 ns (md5 4f8b2108) and -0.234 ns
   (md5 ed40383164, Overlay Bright) on the 125 MHz vfb clock, HDMI clock
   positive both times. No artifacts observed by capture at either, but a
   build that lands further negative deserves a reseed before deploying.
   The deployed OSD-restructure build needed exactly that: seed 1 came out
   -0.370/-0.169 (first HDMI-negative build; still synced on the bench),
   `SEED 3` in the qsf gave -0.012/+0.159 (md5 727c612d, deployed). The
   SEED line stays uncommitted like the rest of the qsf churn, so a future
   rebuild starts from seed 1 again - check slack, reseed as needed.

---

## Overlays: working (2026-08-06)

The overlay feature is on hardware and verified by capture: VART artwork
loads from the OSD ("Load Overlay", F2, extension ART) and composites after
CRT presentation. The compositor is a transmissive filter model, not the
vendored screen blend: vectors are multiplied by the overlay's transmission
color (a white beam under Armor Attack's green playfield renders green, as
the original core's alphablend did), unlit artwork shows as ambient
reflection, and the OSD blend selector sets the ambient strength. 163 titles are tracked in artwork/generated/
and deployed to /media/fat/games/VECTREX/; tools/overlays/build_vart.py
converts one PNG, merge_sources.py rebuilds the whole set picking the best
source per title. Four traps that cost this feature a day:

- CONF_STR extensions are three characters. "F2,VART" silently parses as
  VAR + T and the browser shows no files; the slot is "F2,ART".
- The core reset included ioctl_download, which wiped the overlay upload as
  it arrived. Reset now gates on rom_download (cartridge indexes only).
- The vendored vfb_overlay whitelists artwork plane dimensions, and shipped
  with the Asteroids cabinet's rasters. A valid container passes CRC and all
  metadata checks but package_valid stays low. Patched to the Vectrex
  rasters, both orientations (PROVENANCE.md notes it); found by simulating
  the upload in isolation (sim/overlay_tb, Icarus).
- Upload writes now stop at the artwork window's end: the F2 slot streams
  whatever file the user picks, unlike the Asteroids MRA part which always
  fits.

The MS2109 capture card also serves ~50 frames of stale replay after each
stream open, and can serve stale indefinitely if something (Zoom) held it;
capture at least 150 frames and treat byte-identical repeats as stale. In
the MiSTer OSD, values cycle with confirm - left/right switch menu pages.

Ambient brightness is an OSD option ("Overlay Bright", status[27:25],
100% down to 30%). The vendored blend selector default put unlit artwork
at 26/64 of its color, visibly dimmer than the original core's alphablend;
the table is now a straight ladder and 100% (64/64) is the default, which
is the original look. Verified with Pole Position: ambient regions measure
2.5x brighter, the 64/26 ratio (commit 60f8594).

An .mgl loads core + cartridge + overlay in one shot, much faster than OSD
navigation - file entries with index 1 (cart) and index 2 (overlay),
absolute paths work:

    <mistergamedescription>
        <rbf>_console/vectrex_dev</rbf>
        <file delay="2" type="f" index="1" path="/media/fat/games/VECTREX/Games/Pole Position (1983)(GCE).bin"/>
        <file delay="4" type="f" index="2" path="/media/fat/games/VECTREX/pole.art"/>
    </mistergamedescription>

then `echo 'load_core /media/fat/pole_test.mgl' > /dev/MiSTer_cmd`.

Auto-load works as it did on master: main's generic addon mechanism (the
lowercase `"f1,ART;"` CONF_STR entry, directly before the cart's F entry)
loads `<rom name>.art` from the ROM's folder automatically after every
cartridge load, including MGL loads. The addon arrives with the addon
number in ioctl_index[9:8], not index 2, so vfb_overlay's upload_active
accepts both (the original core's bg_download decode). Nothing lives in
the C binary specifically for this - process_addon in menu.cpp is
generic, keyed entirely off the CONF_STR entry.

Two more capture-loop traps, established 2026-08-06:

- Opening or closing the capture card's video stream tickles the HDMI link
  enough that MiSTer main re-detects video and shows the framework info box
  for video_info (5) seconds - which the first non-stale frames of the new
  stream then catch. It looks like the core's video mode is flapping
  (measured rate readings also wobble one LSB, 44.84 vs 44.86 KHz). It is
  the act of capturing: three idle minutes produce zero MiSTer_fb re-init
  events in /var/log/messages, and the box times out mid-recording. Do not
  chase "unstable video timing" from info-box sightings alone.
- Pole Position's HUD flashing is the game, not the core. The heavy racing
  display list overruns 20 ms, so the game runs at ~25 Hz and draws HUD
  elements in alternating groups: score digits every frame (steady at
  p99.5=246 in capture), GAME OVER and the speed readout on alternating
  frames in anti-phase (p99.5 swings 190/159). Real hardware flickers
  exactly like this; renderer persistence holds off-frames at ~65% so it
  reads as shimmer rather than blinking. The frame marker stays healthy
  throughout (sim: Wait_Recal 6.6 ms holds every 20 ms on the title
  screen, nowhere near the 40 ms watchdog; capture: zero single-frame
  dropouts in 1041 frames).

---

## Reference material

`refs/` is gitignored and holds: the Asteroids, Major Havoc, Tempest, Star Wars
and Battlezone cores; the vecx emulator; the Vectrex service manual as a PDF;
and a curated set of test ROMs including the rev 4 Test Cartridge, whose
expected output the manual documents with pass/fail criteria on pages 20-23.
