# Alpha census — canonical native sources

34 images. Body = what survives a 2-pixel erosion, so antialias rims are excluded and only mis-authored areas are counted.

## Verdicts

| Verdict | Images | Meaning |
|---|---:|---|
| clean | 23 | no near-opaque body pixels; the blocking areas are exactly 255 |
| minor | 8 | under 0.1% of the plane is near-opaque body |
| defect | 3 | 0.1% or more of the plane is near-opaque body |

2 of 34 images never reach alpha 0, so no part of the plane is fully clear. That is not a defect by itself, but the crop cannot be found by looking for a transparent hole:

- `Vryzon.png`
- `Wormhole.png`

## Solid-area alpha actually used

The modal alpha of every body pixel above 199 — the level this artwork treats as solid.

| Alpha | Images |
|---:|---:|
| 255 | 33 |
| 238 | 1 |

## Alpha quantization of the sources

| Ladder | Images |
|---|---:|
| 8bit | 30 |
| 4bit_x17 | 3 |
| 4bit_other | 1 |

## Near-opaque bodies, worst first

Leak is the fraction of a full-brightness vector that passes through the offending pixels, by the compositor's own arithmetic.

| Image | Plane | Body px | % of plane | Modal alpha | Mean leak | Max leak |
|---|---|---:|---:|---:|---:|---:|
| Vector Blade.png |  | 59005 | 15.1762% | 238 | 19.87% | 100.0% |
| Rip Off.png |  | 3655 | 0.4% | 249 | 96.39% | 96.47% |
| Patriots.png |  | 937 | 0.1026% | 253 | 99.5% | 100.0% |
| Wormhole.png |  | 131 | 0.0143% | 253 | 100.0% | 100.0% |
| Spike Hoppin'.png |  | 126 | 0.0138% | 248 | 95.93% | 100.0% |
| Armor Attack.png |  | 42 | 0.0046% | 254 | 2.39% | 13.33% |
| Protector.png |  | 13 | 0.0014% | 254 | 41.78% | 95.69% |
| Star Trek.png |  | 10 | 0.0011% | 254 | 54.71% | 78.43% |
| Bedlam.png |  | 1 | 0.0001% | 245 | 89.41% | 89.41% |
| Cosmic Chasm.png |  | 1 | 0.0001% | 215 | 45.88% | 45.88% |
| Spike.png |  | 1 | 0.0001% | 249 | 91.76% | 91.76% |

## Translucent bodies

34 of 34 images carry a genuinely translucent area larger than 0.5% of the plane. A global alpha threshold in the core would promote these to blockers.

| Image | Plane | Body px | % of plane | Modal alpha |
|---|---|---:|---:|---:|
| Vec Pilot.png |  | 756245 | 82.7691% | 50 |
| Wormhole.png |  | 755005 | 82.6334% | 51 |
| Bedlam.png |  | 739938 | 80.9844% | 51 |
| Polar Rescue.png |  | 722684 | 79.096% | 50 |
| Patriots.png |  | 721672 | 78.9852% | 50 |
| Rip Off.png |  | 720955 | 78.9067% | 50 |
| Star Trek.png |  | 719103 | 78.704% | 51 |
| Spike Hoppin'.png |  | 718433 | 78.6307% | 40 |
| Dark Tower.png |  | 717550 | 78.5341% | 51 |
| Solar Quest.png |  | 716685 | 78.4394% | 51 |
| Web Wars.png |  | 716241 | 78.3908% | 51 |
| Pole Position.png |  | 716120 | 78.3776% | 50 |
| Bubble Splitter.png |  | 304417 | 78.2966% | 136 |
| Hyper Chase.png |  | 715120 | 78.2681% | 50 |
| Scramble.png |  | 711141 | 77.8326% | 50 |
| Blitz.png |  | 710337 | 77.7446% | 50 |
| Fortress of Narzod.png |  | 701759 | 76.8058% | 50 |
| Vryzon.png |  | 701437 | 76.7705% | 64 |
| Space Wars.png |  | 698131 | 76.4087% | 51 |
| Clean Sweep.png |  | 694674 | 76.0303% | 51 |
| Star Castle.png |  | 683078 | 74.8497% | 51 |
| Star Hawk.png |  | 677201 | 74.118% | 50 |
| Vector Patrol.png |  | 676918 | 74.087% | 50 |
| Spike.png |  | 673807 | 73.7465% | 50 |
| Rotor.png |  | 642828 | 70.3559% | 128 |
| Protector.png |  | 642067 | 70.2726% | 70 |
| Berzerk.png |  | 627193 | 68.6447% | 51 |
| Mine Storm.png |  | 621689 | 68.0423% | 50 |
| Cosmic Chasm.png |  | 619098 | 67.7587% | 50 |
| Spinball.png |  | 605002 | 66.216% | 50 |
| Frogger.png |  | 596316 | 65.2653% | 100 |
| Gyrostronomy.png |  | 248744 | 63.9774% | 68 |
| Armor Attack.png |  | 581423 | 63.6353% | 50 |
| Vector Blade.png |  | 234199 | 60.2364% | 153 |
