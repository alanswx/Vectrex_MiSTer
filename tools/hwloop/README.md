# Hardware-loop input injection

`vpad.py` runs **on the MiSTer** (deployed at `/media/fat/vpad.py`) and
creates a virtual gamepad through `/dev/uinput`. It clones the identity of
the bench controller (045e:028e, "Microsoft X-Box 360 pad"), so MiSTer
applies the existing mapping in `config/inputs/input_045e_028e_v3.map` and
the virtual pad drives player 1 with no configuration. This is what lets
the remote loop press Vectrex buttons — the mrext keyboard API only covers
MiSTer system keys.

```
ssh root@192.168.1.75 'python3 /media/fat/vpad.py [--hold S] [--gap S] btn [btn ...]'
```

Buttons: `a b x y tl tr select start mode`, dpad `up down left right`, raw
evdev codes as numbers, and bare float tokens (e.g. `1.5`) as extra sleeps
between presses. Under the bench map, `b a y x` = Vectrex Buttons 1 2 3 4.

To find a sequence before playing it on hardware, rehearse it in vecx with
`tools/goldenref/vecbtn` (`--press START:LEN:MASK`, 1/30 s frames, mask
bit N = player-1 button N+1). The rev 4 Test Cartridge walk from linearity
grid to the INTENSITY screen, verified both places, is:

```
python3 /media/fat/vpad.py --hold 0.25 --gap 0 x 1.05 x 0.45 x 4.4 x 4.75 x 3.05 x
```

See docs/HANDOFF.md ("Vectrex buttons ARE pressable remotely") for the
full Test Cartridge screen order and its traps.
