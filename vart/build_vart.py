#!/usr/bin/env python3
"""Build four-plane Vectrex overlay packages.

Normal operation packs one orientation from four exact-raster PNGs:

    build_vart.py pack INPUT_DIR OUTPUT.art

INPUT_DIR must contain 1080p.png, 720p.png, 480p.png, and 240p.png.

To build every orientation in one operation, provide the same four files below
INPUT_DIR/normal and INPUT_DIR/90CW:

    build_vart.py pack-all INPUT_DIR --name minestorm -o OUTPUT_DIR

This writes minestorm.art, minestorm_90CW.art, and
minestorm_90CCW.art. The counter-clockwise planes are exact 180-degree
rotations of the clockwise inputs. Each output remains an independent
four-plane package; the RTL therefore needs no orientation metadata.

The migrate commands rebuild legacy VART packages into the same three-file
layout. They are intended for the bundled pre-full-raster artwork collection,
not as a substitute for authoring the eight exact input PNGs.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import os
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image

import rgba_ops
import vart_encoder as vart


# label: (full raster, normal artwork frame, quarter-turn artwork frame)
RASTERS = {
    "1080p": ((1360, 1080), (275, 0, 810, 1080), (140, 135, 1080, 810)),
    "720p": ((916, 720), (188, 0, 540, 720), (98, 90, 720, 540)),
    "480p": ((720, 480), (157, 0, 405, 480), (0, 0, 720, 480)),
    "240p": ((720, 240), (157, 0, 405, 240), (0, 0, 720, 240)),
}

# The plane geometry rtl/videodr0me_fb/vfb_overlay.sv actually accepts
# (valid_dimensions, lines 112-119). Each plane IS the artwork frame: no
# margins, so portrait is exactly 3:4 and rotated exactly 4:3 at every size,
# and the core does no resizing, centering or rotation.
NATIVE_RASTERS = {
    "1080p": ((810, 1080), (1080, 810)),
    "720p": ((540, 720), (720, 540)),
    "480p": ((360, 480), (480, 360)),
    "240p": ((180, 240), (240, 180)),
}


def native_orientations(
    portrait: Image.Image,
) -> tuple[dict[str, Image.Image], dict[str, Image.Image]]:
    """Frame a portrait source into the core's whitelisted plane sizes."""
    turned = portrait.transpose(Image.Transpose.ROTATE_270)
    normal: dict[str, Image.Image] = {}
    clockwise: dict[str, Image.Image] = {}
    for label, (upright, rotated) in NATIVE_RASTERS.items():
        normal[label] = rgba_ops.resize_rgba(portrait, upright)
        clockwise[label] = rgba_ops.resize_rgba(turned, rotated)
    return normal, clockwise


LEGACY_NORMAL = {
    "1080p": ((810, 1080), (1360, 1080)),
    "720p": ((540, 720), (916, 720)),
    "480p": ((360, 480), (720, 480)),
    "240p": ((180, 240), (720, 240)),
}

LEGACY_90CW = {
    "1080p": ((1080, 810),),
    "720p": ((720, 540),),
    "480p": ((480, 360),),
    "240p": ((240, 180),),
}

MAX_COLORS = 255


def quantize_rgba(image: Image.Image, colors: int = MAX_COLORS) -> Image.Image:
    """Quantize RGBA while holding the opaque control boundary exact.

    Two things push a blocker off 255. The artwork may arrive near-opaque, and
    Pillow's octree quantizer averages opaque and near-opaque pixels into a
    palette entry below 255. So the solid bodies are snapped first, and the
    contract is then enforced again on the quantized result by lifting the
    palette entries responsible -- checking the output rather than trusting the
    input is the only way to know the boundary survived. Rims and genuine tint
    are untouched throughout.
    """
    rgba, _ = rgba_ops.snap_solid_body(image.convert("RGBA"))
    quantized = rgba.quantize(colors=colors, method=Image.Quantize.FASTOCTREE)

    mapped = quantized.convert("RGBA")
    table = bytearray([255] * 256)
    seen = set()
    for index, pixel in zip(quantized.tobytes(), mapped.getdata()):
        if index not in seen:
            table[index] = 255 if pixel[3] >= 254 else pixel[3]
            seen.add(index)

    width, height = rgba.size
    indices = np.frombuffer(quantized.tobytes(), dtype=np.uint8).reshape(height, width)
    for _ in range(4):
        effective = np.frombuffer(bytes(table), dtype=np.uint8)[indices]
        offending = rgba_ops.solid_body(effective)
        if not offending.any():
            break
        for index in np.unique(indices[offending]):
            table[int(index)] = rgba_ops.OPAQUE

    quantized.info["transparency"] = bytes(table)
    return quantized


def load_exact_set(directory: Path) -> dict[str, Image.Image]:
    images: dict[str, Image.Image] = {}
    for label, (raster, _, _) in RASTERS.items():
        source = directory / f"{label}.png"
        if not source.is_file():
            raise vart.ArtworkError(f"missing required input {source}")
        with Image.open(source) as image:
            if image.size != raster:
                raise vart.ArtworkError(
                    f"{source}: expected {raster[0]}x{raster[1]}, "
                    f"got {image.width}x{image.height}"
                )
            images[label] = image.convert("RGBA").copy()
    return images


def encode_set(images: dict[str, Image.Image], workdir: Path) -> bytes:
    workdir.mkdir(parents=True, exist_ok=True)
    planes = []
    for label in RASTERS:
        image = images[label]
        plane_png = workdir / f"{label}.png"
        quantize_rgba(image).save(plane_png)
        planes.append(vart.encode_plane(plane_png))

    container = vart.build_container(planes)
    vart.verify_container(container, planes)
    return container


def encode_orientations(
    normal: dict[str, Image.Image],
    clockwise: dict[str, Image.Image],
    workdir: Path,
) -> dict[str, bytes]:
    counter_clockwise = {
        label: image.transpose(Image.Transpose.ROTATE_180)
        for label, image in clockwise.items()
    }
    return {
        "": encode_set(normal, workdir / "normal"),
        "_90CW": encode_set(clockwise, workdir / "90CW"),
        "_90CCW": encode_set(counter_clockwise, workdir / "90CCW"),
    }


def write_atomic(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
        os.replace(temporary, path)
    except Exception:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def write_packages(
    packages: dict[str, bytes], name: str, outdir: Path, verbose: bool = True
) -> dict[str, int]:
    sizes = {}
    for suffix, container in packages.items():
        target = outdir / f"{name}{suffix}.art"
        write_atomic(target, container)
        sizes[target.name] = len(container)
        if verbose:
            print(f"{target.name}: {len(container):,} bytes")
    return sizes


def transparent_canvas(size: tuple[int, int]) -> Image.Image:
    return Image.new("RGBA", size, (0, 0, 0, 0))


def place_frame(
    content: Image.Image,
    raster: tuple[int, int],
    frame: tuple[int, int, int, int],
) -> tuple[Image.Image, Image.Image]:
    x, y, width, height = frame
    fitted = rgba_ops.resize_rgba(content, (width, height))
    canvas = transparent_canvas(raster)
    canvas.alpha_composite(fitted, (x, y))
    return canvas, fitted


def select_legacy_plane(
    planes: list[dict[str, object]], sizes: tuple[tuple[int, int], ...]
) -> Image.Image | None:
    for size in sizes:
        for plane in planes:
            if plane["role"] == vart.ROLE_OVERLAY and (
                plane["width"], plane["height"]
            ) == size:
                image = plane["image"]
                assert isinstance(image, Image.Image)
                return image.copy()
    return None


def legacy_normal_content(
    source: Image.Image,
    raster: tuple[int, int],
    frame: tuple[int, int, int, int],
) -> Image.Image:
    x, y, width, height = frame
    if source.size == raster:
        return source.crop((x, y, x + width, y + height))
    return rgba_ops.resize_rgba(source, (width, height))


def migrate_images(container: bytes) -> tuple[dict[str, Image.Image], dict[str, Image.Image]]:
    planes = vart.decode_container(container)
    overlay_planes = [plane for plane in planes if plane["role"] == vart.ROLE_OVERLAY]
    if not overlay_planes:
        raise vart.ArtworkError("legacy package contains no overlay plane")

    fallback_plane = max(
        overlay_planes, key=lambda plane: int(plane["width"]) * int(plane["height"])
    )
    fallback_image = fallback_plane["image"]
    assert isinstance(fallback_image, Image.Image)

    normal: dict[str, Image.Image] = {}
    clockwise: dict[str, Image.Image] = {}
    for label, (raster, normal_frame, turned_frame) in RASTERS.items():
        normal_source = select_legacy_plane(overlay_planes, LEGACY_NORMAL[label])
        if normal_source is None:
            normal_source = fallback_image.copy()
        normal_content = legacy_normal_content(normal_source, raster, normal_frame)
        normal[label], normal_content = place_frame(normal_content, raster, normal_frame)

        turned_source = select_legacy_plane(overlay_planes, LEGACY_90CW[label])
        if turned_source is None:
            turned_source = normal_content.transpose(Image.Transpose.ROTATE_270)
        clockwise[label], _ = place_frame(turned_source, raster, turned_frame)

    return normal, clockwise


def frame_orientations(
    portrait: Image.Image,
) -> tuple[dict[str, Image.Image], dict[str, Image.Image]]:
    """Frame one full-resolution portrait into every plane of both orientations.

    Each plane is reduced once, straight from the source. Deriving the turned
    planes from the already-framed normal ones cost a second reduction at every
    size below 1080p -- at 240p the rotated artwork was downscaled to 405x240
    and then stretched back up to 720x240.
    """
    turned = portrait.transpose(Image.Transpose.ROTATE_270)
    normal: dict[str, Image.Image] = {}
    clockwise: dict[str, Image.Image] = {}
    for label, (raster, normal_frame, turned_frame) in RASTERS.items():
        normal[label], _ = place_frame(portrait, raster, normal_frame)
        clockwise[label], _ = place_frame(turned, raster, turned_frame)
    return normal, clockwise


def portrait_fallback(source: Path) -> tuple[dict[str, Image.Image], dict[str, Image.Image]]:
    with Image.open(source) as image:
        portrait = image.convert("RGBA").copy()
    return frame_orientations(portrait)


def build_from_portrait(source: Path, workdir: Path) -> dict[str, bytes]:
    normal, clockwise = portrait_fallback(source)
    return encode_orientations(normal, clockwise, workdir)


def migrate_file(
    source: Path,
    outdir: Path,
    name: str | None = None,
    verbose: bool = True,
) -> dict[str, int]:
    normal, clockwise = migrate_images(source.read_bytes())
    with tempfile.TemporaryDirectory() as temporary:
        packages = encode_orientations(normal, clockwise, Path(temporary))
    return write_packages(packages, name or source.stem, outdir, verbose)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    pack = commands.add_parser("pack", help="pack one four-plane orientation")
    pack.add_argument("input", type=Path, help="directory containing the four PNGs")
    pack.add_argument("output", type=Path, help="output .art file")

    pack_all = commands.add_parser(
        "pack-all", help="pack Normal, 90CW, and generated 90CCW packages"
    )
    pack_all.add_argument("input", type=Path, help="directory containing normal/ and 90CW/")
    pack_all.add_argument("--name", help="output basename; defaults to the input directory name")
    pack_all.add_argument("-o", "--outdir", type=Path, required=True)

    migrate = commands.add_parser("migrate", help="migrate one legacy .art package")
    migrate.add_argument("input", type=Path)
    migrate.add_argument("--name", help="output basename; defaults to the input stem")
    migrate.add_argument("-o", "--outdir", type=Path, required=True)

    migrate_all = commands.add_parser(
        "migrate-all", help="migrate every legacy .art package in a directory"
    )
    migrate_all.add_argument("input", type=Path)
    migrate_all.add_argument("-o", "--outdir", type=Path, required=True)
    migrate_all.add_argument(
        "-j", "--jobs", type=int, default=min(8, os.cpu_count() or 1)
    )

    args = parser.parse_args()
    try:
        if args.command == "pack":
            images = load_exact_set(args.input)
            with tempfile.TemporaryDirectory() as temporary:
                container = encode_set(images, Path(temporary))
            write_atomic(args.output, container)
            print(f"{args.output}: {len(container):,} bytes")
        elif args.command == "pack-all":
            normal = load_exact_set(args.input / "normal")
            clockwise = load_exact_set(args.input / "90CW")
            with tempfile.TemporaryDirectory() as temporary:
                packages = encode_orientations(normal, clockwise, Path(temporary))
            write_packages(packages, args.name or args.input.name, args.outdir)
        elif args.command == "migrate":
            migrate_file(args.input, args.outdir, args.name)
        else:
            sources = sorted(
                path for path in args.input.glob("*.art")
                if not path.stem.endswith(("_90CW", "_90CCW"))
            )
            if not sources:
                raise vart.ArtworkError(f"{args.input}: no .art files found")
            if args.jobs < 1:
                raise vart.ArtworkError("--jobs must be at least one")
            print(
                f"migrating {len(sources)} titles with {args.jobs} workers; "
                "a full run normally takes tens of minutes"
            )
            completed = 0
            with concurrent.futures.ProcessPoolExecutor(max_workers=args.jobs) as pool:
                pending = {
                    pool.submit(migrate_file, source, args.outdir, None, False): source
                    for source in sources
                }
                for future in concurrent.futures.as_completed(pending):
                    source = pending[future]
                    sizes = future.result()
                    completed += 1
                    package_size = sum(sizes.values())
                    print(
                        f"[{completed}/{len(sources)}] {source.name}: "
                        f"{package_size:,} bytes"
                    )
            print(f"migrated {len(sources)} titles into {len(sources) * 3} packages")
    except (OSError, vart.ArtworkError) as error:
        print(f"FAILED: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
