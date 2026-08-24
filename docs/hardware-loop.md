# Hardware loop reference

How to build, deploy, drive and measure this core on the bench, and the
traps each step has. Operational reference only — status and plans live in
`docs/HANDOFF.md`.

## Bench

- MiSTer at `192.168.1.75`, ssh as root with the existing key. mrext's
  Remote service is on port 8182.
- **The MiSTer is shared.** Check `/tmp/CORENAME` before trusting any
  capture, and don't drive it while someone else is testing.

## Build and deploy

```bash
quartus_sh --flow compile Vectrex
scp output_files/Vectrex.rbf root@192.168.1.75:/media/fat/_Console/Vectrex_dev.rbf
# md5sum both ends before believing a deploy
```

- Quartus rewrites `Vectrex.qsf` every build; revert it
  (`git checkout -- Vectrex.qsf`), never commit it.
- **Seed lottery**: the 125 MHz renderer clock closes within ±0.4 ns of
  zero and the HDMI output path is placement-sensitive. Check slack on
  every build; if it lands notably negative, add `set_global_assignment
  -name SEED <n>` to the qsf and refit. The SEED line stays uncommitted.
- Diagnostic switches: `LEGACY_VIDEO` in `Vectrex.sv` and `DIAG_SIMPLE`
  in `rtl/vectrex_video.sv` restore the original video path.

## Launching

```bash
# by API
curl -X POST -H 'Content-Type: application/json' \
  -d '{"path":"/media/fat/games/VECTREX/Games/<rom>.bin"}' \
  http://192.168.1.75:8182/api/games/launch

# by MGL (core + cart + overlay in one shot)
echo 'load_core /media/fat/whatever.mgl' > /dev/MiSTer_cmd
```

```xml
<mistergamedescription>
    <rbf>_console/vectrex_dev</rbf>
    <file delay="2" type="f" index="1" path="/media/fat/games/VECTREX/Games/Pole Position (1983)(GCE).bin"/>
    <file delay="4" type="f" index="2" path="/media/fat/games/VECTREX/pole.art"/>
</mistergamedescription>
```

The game-launch API can return HTTP 200 without changing cartridges. Confirm
the next screenshot actually changed before starting a closed-loop test. After
the 2026-08-09 full sweep it remained stale even across a core reload, which
prevented a redundant native-720 Test Cartridge sweep; do not interpret the
resulting `never reached grid` exception as a renderer failure.

## Framework screenshots

POST `/api/screenshots`, confirm the newest `modified` timestamp advanced
(the API returns 200 without capturing sometimes), then GET the newest
entry's URL-encoded path. Screenshots capture the core's video **before**
the output stages — a clean screenshot proves nothing about HDMI/VGA.

## HDMI capture card

MiSTer HDMI passes through a MiraBox MS2109 whose USB lands on this
machine: video at the `/dev/video*` node with udev `ID_MODEL
MiraBox_Capture` (currently `/dev/video4`), audio at ALSA card `MS2109`.
The bench is currently left at native 1280x720@60 (`video_mode=0`) after the
2026-08-09 presentation test; the previous setting was 1920x1080@60
(`video_mode=8`). The MS2109 delivers 1080p at 30 fps MJPEG; 60 fps needs
1280x720. The pre-test global configuration is backed up on the MiSTer as
`/media/fat/MiSTer.ini.pre_vectrex_720p_20260809`.

```bash
ffmpeg -f v4l2 -input_format mjpeg -video_size 1920x1080 -i /dev/video4 \
  -vf "select='gte(n,160)'" -frames:v 1 -fps_mode passthrough shot.png
```

Traps:

- The card serves ~150 stale frames after each stream open — skip them,
  and treat byte-identical repeats as stale.
- An app holding the device (Zoom) makes it serve stale/no-signal frames
  forever; quit the app and `USBDEVFS_RESET` the USB device.
- The chip latches no-signal at power-up; reset it after input changes.
- Requesting 1280x720 from the MiraBox does **not** prove the MiSTer source is
  720p; the dongle will downscale a 1080p input and can introduce hairline
  beading. Capture at the source resolution when judging scaler artifacts.
- At native 720p, use the core render setting `Match output`. The 1080p render
  target downscaled to native 720p beads vertical hairlines in both framework
  and raw HDMI captures; Match output produces a 540x720 active image with
  continuous vectors. The full 98-title/588-frame review is recorded in
  `game_sweep_native720_match_full_20260809/`.
- **Opening or closing the stream re-triggers MiSTer's video info box**
  for ~5 s and wobbles the reported rate one LSB. It looks like the
  core's video is flapping; it is the act of capturing. It also paints
  the info box over whatever is on screen — do not open the stream while
  someone else is using the bench.

## Input injection

mrext's keyboard API (`POST /api/controls/keyboard/{name}`) covers only
MiSTer system keys (`osd`, `up`, `down`, `confirm`, ... — note the OSD
opens with `osd`, not `menu`). Vectrex buttons come from
`tools/hwloop/vpad.py` (deployed at `/media/fat/vpad.py`): a uinput
virtual gamepad cloning the bench pad's identity (045e:028e), so the
existing mapping applies and it drives player 1 unconfigured. Evdev
`b a y x` = Vectrex Buttons 1 2 3 4; bare float tokens are sleeps.

## Test Cartridge (rev 4) navigation

Button 4 = next screen, Button 3 = previous. Order: linearity grid
(auto, ~14 s after launch) → ADJUST DAC OFFSET → INTEGRATOR OFFSET →
FORMING CHECKSUM → DEFLECTION PROTECT (auto-runs into BEAM CUTOFF) →
SOUND TEST → INTENSITY → FOCUS → DISTORTION → DISTORTION 2 →
KEY/JOYSTICK. The two scope screens accept presses only while their
words are on screen (~3 s window every ~6 s); the sound test only
during a words phase; KEY/JOYSTICK is a trap — no button leaves it,
relaunch the cart. Grid to INTENSITY in one shot:

```bash
ssh root@192.168.1.75 'python3 /media/fat/vpad.py --hold 0.25 --gap 0 \
  x 1.05 x 0.45 x 4.4 x 4.75 x 3.05 x'
```

The expected checksum is **6293** with the default Bug-fixed BIOS and **B796**
with Factory selected. Use `tc_sweep.py --expected-bios fixed|factory`; see
`docs/beam-model.md` for why the values differ.

## Regression suites

- `tools/hwloop/tc_sweep.py` — walks every Test Cartridge screen
  closed-loop and checks screen identity, checksum digits, and the
  INTENSITY criteria. Exit 0 = green.
- `tools/hwloop/game_sweep.py` — full-catalog attract-mode regression
  against vecx references; `gen-refs`/`validate` are offline, `run`
  needs `--yes-touch-the-mister`. See `tools/hwloop/README.md`.

## Simulation and references

- `sim/run.sh` — the core under ghdl, ~0.7 s wall clock per emulated
  millisecond. **Simulation matches silicon 100%**, verified against a
  hardware capture of the Linearity Pattern, so simulated measurements
  stand for the real core.
- `tools/goldenref/` — `vecdump` (vecx segment lists, ~1 s per run;
  the fast loop for cartridge debugging), `compare.py`, `beamspeed.py`,
  `vecbtn` (scriptable button/joystick timeline for rehearsing input
  sequences before playing them on hardware).
- `tools/testcart/make_calcart.py` — boot-to-pattern calibration cart
  (intensity ladder, dwell pair, dot row); its docstring records the
  cart-authoring traps (empty title list hangs the BIOS; naive Moveto_d
  at scale $FF rails the integrators).
- `refs/` (gitignored) — reference cores, vecx, service manual
  (Test Cartridge criteria pp. 18-23), ROMs, real-hardware footage.

## OSD notes

- Values cycle with confirm; left/right switch menu pages.
- CONF_STR `-,text;` info lines truncate at inner commas.
- File-browser extensions are exactly three characters (`F2,ART`).

## Repo trap

`Vectrex.sv` and `.gitignore` have mixed CRLF/LF line endings. Match
`\r?\n` in scripted edits and grep afterwards to confirm the edit landed;
three separate silent no-op edits have cost real time.
