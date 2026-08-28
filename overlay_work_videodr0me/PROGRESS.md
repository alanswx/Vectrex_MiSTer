# Overlay research progress

Updated 2026-08-28.

## Scope

The working inventory is based on `LOW_RESOLUTION.md` and
`CANONICAL_TITLES.md`. The target is the largest native source available for
each overlay, preferably an original scan or lossless PNG/TIFF/PSD/vector
file. No assets were converted to the existing `_Small.png` format.

## Downloaded assets

The following files were downloaded into `web_downloads/` and kept separate
from the production `overlays/` directory:

| Asset | Native size | Assessment |
|---|---:|---|
| `Vectorblade_overlay_author.png` | 1656x1360 | Author-linked PNG; strongest replacement for the 540x720 decode |
| `Gyrostronomy_overlay_author.png` | 963x1240 | Official project PNG; source page requests non-commercial use and credit |
| `Hera_Primera_overlay_reference.jpg` | 768x1024 | Reference photograph of a confirmed physical overlay; not production-ready |
| `Menschenjagd_overlay_reference.jpg` | 1050x1400 | Reference photograph of a confirmed physical overlay; not production-ready |

The exact URLs and SHA-256 hashes are recorded in `web_downloads/README.md`.

## Research findings

- `Vectorblade`: the author’s release material links an overlay PNG. A native
  1656x1360 copy is staged locally.
- `Bubble Splitter`: still only has the 540x720 decoded source locally. No
  larger clean source was located in this pass.
- `Gyrostronomy`: an official PNG is available and staged locally.
- `Hera Primera`: a physical overlay definitely exists; the overlay designer
  is credited as Oliver “v3to” Lindau. A reference photo is staged.
- `Menschenjagd`: a physical overlay definitely exists and is credited to
  Jacek Selanski. A reference photo is staged.
- `Chimney Hunt`: the released package is documented as including a full-color
  screen overlay, but no clean digital source was located.
- `Alpine Rescue`: the creator has offered overlays directly to owners of the
  digital release; no downloadable source was located.
- `Big Blue` and `Vectrexagon`: vector artwork is listed by Tony Holcomb, but
  the site marks the files private-use only. Permission and direct asset
  retrieval remain outstanding.
- `Space Frenzy`: John Dondzila stated that he could not make an overlay
  cost-effective, so this may be a genuine no-overlay title despite database
  listings.
- `Revector`: release and overlay references exist, but no clean downloadable
  artwork was verified.
- `Cantina Band`: the official source provides the ROM, not overlay artwork.

## Still unresolved

No verified clean source was found for Tail Gunner, Tron, Neon Hawk, Incoming,
Spider Fish, Becky’s Message, Buzz Off, Patriots 2, Revector, Big Blue,
Vectrexagon, or Cantina Band. These should be pursued through the original
authors, publishers, collectors, and physical-overlay scans before using AI
upscaling.

## Handling rules

Do not copy these files into `overlays/` yet. First validate geometry, alpha,
playfield darkness, and the absence of burned-in gameplay vectors. Keep
photographic references separate from clean source art, and retain the source
license/permission notes before redistribution.
