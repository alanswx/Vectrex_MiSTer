# Videodr0me overlay pack workspace

This directory is the non-destructive staging area for the canonical Vectrex
overlay pack requested by Videodr0me. The original `overlays/`,
`refs/overlay_sources/`, and `artwork/generated/` trees remain untouched.

## Current first-pass result

- 50 ranked titles normalized into one canonical list.
- 34 titles have a selected source in `canonical/`.
- 16 ranked titles have no local overlay source.
- Cantina Band is an additional priority title. Its author-published ROM is in
  `source_review/`, but it has no local overlay.
- Three selected sources are genuinely low resolution (540x720).
- Star Castle is 845x1080, only one pixel narrower than the 846x1080 baseline.
- Candidate selection favors the darker/translucent 846x1080 pack. In
  particular, Mine Storm uses `mine.png`; the opaque `minestorm.png` lineage
  is rejected.
- No `.art` pack has been generated yet. The current generator lacks TATE
  plane generation; see `TATE_STATUS.md`.

## Directory layout

- `canonical/`: normalized best source selected for each covered title.
- `source_review/`: downloaded archives, extracted sources, and decoded legacy
  RGBA4444 artwork.
- `rejected_duplicates/`: decisions about alternates and duplicates.
- `output/normal`, `output/90CW`, `output/90CCW`: reserved final outputs.
- `test_results/`: contact sheets and later hardware/crop results.

See `CANONICAL_TITLES.md`, `LOW_RESOLUTION.md`, and `ALPHA_AUDIT.md` before
searching for or regenerating art.
