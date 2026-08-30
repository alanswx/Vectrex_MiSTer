#!/usr/bin/env python3
"""Alpha-correct resampling and the opaque-body contract.

Two rules, both forced on us by measurement (see
``overlay_work_videodr0me/ALPHA_PLAN.md``):

*Resample premultiplied, in linear light.* Straight-alpha resampling in sRGB
mixes colour across an alpha edge as if the transparent side had a colour,
which darkens or halos every boundary and drags interior alpha off its
authored value. The census found the damage rising with each reduction: 59% of
the 1360x1080 planes were clean against 21% of the 720x240 ones.

*Alpha 255 is a control boundary, not a shade.* The compositor multiplies the
beam by ``255 - (255 - art) * alpha / 256``, so a blocker at 254 leaks 0.8% of
the vector and one at 210 leaks 18%. Anything the artwork meant as solid has
to arrive at exactly 255. Rims are the exception: the intermediate alpha in the
two pixels either side of a hard edge is antialiasing, and flattening it would
be worse than the leak. Erosion separates the two -- a rim erodes away, a
mis-authored body does not.
"""

from __future__ import annotations

import numpy as np
from PIL import Image


# The band the contract calls "meant to be solid". 200 is deliberately
# generous: the worst source in the pack authors its frame at 210.
SOLID_FLOOR = 200
OPAQUE = 255

# Rim width, in pixels, that counts as antialiasing rather than authored area.
RIM = 2


def _srgb_to_linear(channel: np.ndarray) -> np.ndarray:
    return np.where(
        channel <= 0.04045,
        channel / 12.92,
        ((channel + 0.055) / 1.055) ** 2.4,
    )


def _linear_to_srgb(channel: np.ndarray) -> np.ndarray:
    return np.where(
        channel <= 0.0031308,
        channel * 12.92,
        1.055 * np.clip(channel, 0.0, None) ** (1 / 2.4) - 0.055,
    )


def _resize_plane(plane: np.ndarray, size: tuple[int, int], resample: int) -> np.ndarray:
    return np.asarray(
        Image.fromarray(plane.astype(np.float32), mode="F").resize(size, resample),
        dtype=np.float64,
    )


def resize_rgba(
    image: Image.Image,
    size: tuple[int, int],
    resample: int = Image.Resampling.HAMMING,
) -> Image.Image:
    """Resize RGBA premultiplied and in linear light.

    HAMMING stays the reduction filter: sharper than bilinear, without the
    ringing and overshoot a sinc-style filter puts on these hard-edged plastic
    overlays.
    """
    if image.mode != "RGBA":
        image = image.convert("RGBA")
    if image.size == size:
        return image.copy()

    data = np.asarray(image, dtype=np.float64) / 255.0
    alpha = data[:, :, 3]
    linear = _srgb_to_linear(data[:, :, :3])
    premultiplied = linear * alpha[:, :, None]

    out_alpha = _resize_plane(alpha, size, resample)
    out_premultiplied = np.dstack(
        [_resize_plane(premultiplied[:, :, c], size, resample) for c in range(3)]
    )

    np.clip(out_alpha, 0.0, 1.0, out=out_alpha)
    # Where nothing is left, the colour is undefined; keep it black so the
    # encoder does not spend palette entries on invented edge colours.
    safe = np.where(out_alpha > 1e-6, out_alpha, 1.0)[:, :, None]
    out_linear = np.clip(out_premultiplied / safe, 0.0, 1.0)
    out_rgb = _linear_to_srgb(out_linear)

    result = np.dstack([out_rgb, out_alpha[:, :, None]])
    return Image.fromarray(
        np.clip(np.rint(result * 255.0), 0, 255).astype(np.uint8), mode="RGBA"
    )


def erode(mask: np.ndarray, iterations: int = RIM) -> np.ndarray:
    """Erode a boolean mask 4-connected, replicating at the image border.

    Border replication matters: a frame that runs to the edge of the plane is
    authored area, not a rim, and must not be eaten from outside.
    """
    result = mask
    for _ in range(iterations):
        padded = np.pad(result, 1, mode="edge")
        result = (
            padded[1:-1, 1:-1]
            & padded[:-2, 1:-1]
            & padded[2:, 1:-1]
            & padded[1:-1, :-2]
            & padded[1:-1, 2:]
        )
    return result


def solid_body(alpha: np.ndarray, floor: int = SOLID_FLOOR, rim: int = RIM) -> np.ndarray:
    """Near-opaque pixels that are body rather than antialias rim.

    The erosion runs over everything the artwork means as solid, 255 included,
    and only then selects the pixels that fall short. Eroding the near-opaque
    band alone would spare the two pixels where a 232 patch meets a 255 frame,
    and that boundary is interior, not a rim -- there is no translucent side
    to antialias against.
    """
    return erode(alpha >= floor, rim) & (alpha < OPAQUE)


def snap_solid_body(
    image: Image.Image, floor: int = SOLID_FLOOR, rim: int = RIM
) -> tuple[Image.Image, int]:
    """Raise near-opaque bodies to exactly 255, leaving rims alone.

    Returns the image and the number of pixels raised, so callers can report
    what they had to correct.
    """
    if image.mode != "RGBA":
        image = image.convert("RGBA")
    data = np.array(image)
    alpha = data[:, :, 3]
    body = solid_body(alpha, floor, rim)
    raised = int(body.sum())
    if raised:
        alpha[body] = OPAQUE
        data[:, :, 3] = alpha
        image = Image.fromarray(data, mode="RGBA")
    return image, raised


def contract_violations(image: Image.Image, floor: int = SOLID_FLOOR, rim: int = RIM) -> int:
    """Body pixels still sitting between `floor` and 254. Zero means compliant."""
    alpha = np.asarray(image.convert("RGBA"))[:, :, 3]
    return int(solid_body(alpha, floor, rim).sum())
