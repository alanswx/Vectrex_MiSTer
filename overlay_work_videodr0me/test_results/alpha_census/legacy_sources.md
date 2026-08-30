# Alpha census — shipping pack (overlays/, legacy sources)

90 images. Body = what survives a 2-pixel erosion, so antialias rims are excluded and only mis-authored areas are counted.

## Verdicts

| Verdict | Images | Meaning |
|---|---:|---|
| clean | 74 | no near-opaque body pixels; the blocking areas are exactly 255 |
| minor | 5 | under 0.1% of the plane is near-opaque body |
| defect | 9 | 0.1% or more of the plane is near-opaque body |
| opaque_only | 2 | one alpha value, 255; blocks the whole screen |

10 of 90 images never reach alpha 0, so no part of the plane is fully clear. That is not a defect by itself, but the crop cannot be found by looking for a transparent hole:

- `Berzerk_Small.png`
- `Frogger_Small.png`
- `Last_Battle_Small.png`
- `Narzod_Small.png`
- `Pipe_Race_Small.png`
- `Space_Patrol_Small.png`
- `Spike Hoppin'_Small.png`
- `Spike's Wedding_Small.png`
- `Vectrex Pong (1998)_Small.png`
- `Vectrex Pong (1999)_Small.png`

## Solid-area alpha actually used

The modal alpha of every body pixel above 199 — the level this artwork treats as solid.

| Alpha | Images |
|---:|---:|
| 255 | 85 |
| 217 | 2 |
| 210 | 1 |
| 214 | 1 |

## Alpha quantization of the sources

| Ladder | Images |
|---|---:|
| 8bit | 87 |
| binary | 3 |

## Near-opaque bodies, worst first

Leak is the fraction of a full-brightness vector that passes through the offending pixels, by the compositor's own arithmetic.

| Image | Plane | Body px | % of plane | Modal alpha | Mean leak | Max leak |
|---|---|---:|---:|---:|---:|---:|
| Pipe_Race_Small.png |  | 331134 | 85.1682% | 214 | 82.79% | 94.12% |
| Lost_Souls_Small.png |  | 104909 | 26.9828% | 217 | 79.43% | 81.57% |
| Doodle_Jump_Small.png |  | 45733 | 11.7626% | 217 | 57.16% | 94.12% |
| Floor_Is_Lava_Small.png |  | 37142 | 9.553% | 254 | 43.49% | 100.0% |
| Curling_Small.png |  | 34332 | 8.8302% | 210 | 86.7% | 88.24% |
| Treasure_Diver_Small.png |  | 17025 | 4.3789% | 242 | 59.65% | 100.0% |
| All Good Things_Small.png |  | 3184 | 0.8189% | 252 | 97.39% | 100.0% |
| Brick_Crushers_Small.png |  | 1223 | 0.3146% | 233 | 71.82% | 98.04% |
| Star_War_Small.png |  | 418 | 0.1075% | 253 | 81.58% | 99.22% |
| RobHop_Small.png |  | 302 | 0.0777% | 252 | 76.06% | 100.0% |
| Stunt_Man_Stories_Small.png |  | 15 | 0.0039% | 254 | 93.15% | 100.0% |
| Omega Chase_Small.png |  | 4 | 0.001% | 254 | 100.0% | 100.0% |
| Spaceship_Centauri_Small.png |  | 4 | 0.001% | 230 | 9.9% | 10.2% |
| Space_Patrol_Small.png |  | 2 | 0.0005% | 252 | 1.96% | 1.96% |

## Translucent bodies

66 of 90 images carry a genuinely translucent area larger than 0.5% of the plane. A global alpha threshold in the core would promote these to blockers.

| Image | Plane | Body px | % of plane | Modal alpha |
|---|---|---:|---:|---:|
| Hex_Trex_Small.png |  | 351232 | 90.3374% | 79 |
| Spike Hoppin'_Small.png |  | 349006 | 89.7649% | 50 |
| Curling_Small.png |  | 347737 | 89.4385% | 179 |
| Wormhole_Small.png |  | 334555 | 86.0481% | 51 |
| Spike_Goes_Skiing_Small.png |  | 333493 | 85.7749% | 51 |
| Knight_Rider_Small.png |  | 332780 | 85.5916% | 127 |
| All Good Things_Small.png |  | 332715 | 85.5748% | 50 |
| Doodle_Jump_Small.png |  | 329505 | 84.7492% | 99 |
| Patriots_Small.png |  | 328639 | 84.5265% | 51 |
| Pyoro_Chan_Small.png |  | 326303 | 83.9257% | 127 |
| Heads-Up_Action_Soccer_Small.png |  | 325805 | 83.7976% | 51 |
| Pitchers_Duel_Proto_Small.png |  | 323358 | 83.1682% | 51 |
| Space_Patrol_Small.png |  | 322854 | 83.0386% | 110 |
| Star_Hawk_Small.png |  | 319901 | 82.2791% | 51 |
| Pole_Position_Small.png |  | 318819 | 82.0008% | 51 |
| Shark_Attack_Small.png |  | 318702 | 81.9707% | 128 |
| Bedlam_Small.png |  | 318417 | 81.8974% | 51 |
| Star_Trek-The_Motion_Picture_Small.png |  | 317625 | 81.6937% | 51 |
| Rip_Off_Small.png |  | 317397 | 81.635% | 51 |
| HyperChase_Auto_Race_Small.png |  | 316929 | 81.5147% | 51 |
| Blitz__Action_Football_Small.png |  | 316923 | 81.5131% | 51 |
| Asteroid_Cowboy_Small.png |  | 316596 | 81.429% | 128 |
| Hover_Race_Small.png |  | 316596 | 81.429% | 128 |
| Kingdom_Of_Heaven_Small.png |  | 316596 | 81.429% | 128 |
| Portal_Fight_Small.png |  | 316596 | 81.429% | 128 |
| Space_Ball_Small.png |  | 316596 | 81.429% | 127 |
| Dark_Tower_Proto_Small.png |  | 316192 | 81.3251% | 51 |
| Web_Wars_Small.png |  | 316043 | 81.2868% | 51 |
| Scramble_Small.png |  | 316019 | 81.2806% | 51 |
| Star_Ship_Small.png |  | 315787 | 81.2209% | 51 |
| Polar_Rescue_Small.png |  | 315486 | 81.1435% | 51 |
| Solar_Quest_Small.png |  | 315160 | 81.0597% | 51 |
| Omega Chase_Small.png |  | 314461 | 80.8799% | 51 |
| 2D_Narrow_Escape_Small.png |  | 313026 | 80.5108% | 51 |
| Space_Assault_Small.png |  | 312438 | 80.3596% | 128 |
| ArmorAttack_Small.png |  | 311576 | 80.1379% | 51 |
| Mine_Storm_Small.png |  | 311509 | 80.1206% | 51 |
| Pac_Men_Small.png |  | 311247 | 80.0532% | 128 |
| Thirsty_Astronaut_Small.png |  | 308880 | 79.4444% | 127 |
| Eating_Fish_Small.png |  | 307133 | 78.9951% | 128 |
