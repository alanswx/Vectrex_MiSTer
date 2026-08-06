#!/usr/bin/env python3
"""Build a VART artwork package and embed it in a MiSTer MRA.

Vendored unmodified from Arcade-Asteroids_MiSTer/artwork/build_artwork.py
(videodr0me, 2026-08-05) so the Vectrex overlay pipeline does not depend on
the gitignored refs/ checkout. Local code should import from it rather than
edit it; see build_vart.py alongside.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import struct
import tempfile
import xml.etree.ElementTree as ET
import zlib

from PIL import Image


MAGIC = b"VART"
VERSION = 1
HEADER_SIZE = 64
DESCRIPTOR_SIZE = 48
MAX_CONTAINER_BYTES = 4 * 1024 * 1024
ROW_ALIGNMENT = 8
ROM_INDEX = 2

ROLE_BACKGROUND = 0
ROLE_FOREGROUND = 1
ROLE_NAMES = {
    ROLE_BACKGROUND: "background",
    ROLE_FOREGROUND: "foreground",
}

ASTEROIDS_PLANES = {
    (1360, 1080),
    (916, 720),
    (640, 480),
    (640, 240),
}


class ArtworkError(RuntimeError):
    """A user-facing artwork validation or generation error."""


def align(value: int, alignment: int = ROW_ALIGNMENT) -> int:
    return (value + alignment - 1) & ~(alignment - 1)


class BitWriter:
    def __init__(self) -> None:
        self.data = bytearray()
        self.pending = 0
        self.pending_bits = 0
        self.bit_count = 0

    def write(self, value: int, width: int) -> None:
        if value < 0 or value >= (1 << width):
            raise ArtworkError(f"value {value} does not fit in {width} bits")
        self.pending |= value << self.pending_bits
        self.pending_bits += width
        self.bit_count += width
        while self.pending_bits >= 8:
            self.data.append(self.pending & 0xFF)
            self.pending >>= 8
            self.pending_bits -= 8

    def finish(self) -> tuple[bytes, int]:
        if self.pending_bits:
            self.data.append(self.pending & 0xFF)
        return bytes(self.data), self.bit_count


class BitReader:
    def __init__(self, data: bytes, bit_count: int) -> None:
        self.data = data
        self.bit_count = bit_count
        self.position = 0

    def read(self, width: int) -> int:
        if self.position + width > self.bit_count:
            raise ArtworkError("compressed row ends inside a token")
        value = 0
        for bit in range(width):
            source_bit = self.position + bit
            value |= ((self.data[source_bit >> 3] >> (source_bit & 7)) & 1) << bit
        self.position += width
        return value


class RangeMinTree:
    """Incremental range-min tree used by the row packet optimizer."""

    def __init__(self, count: int) -> None:
        size = 1
        while size < count:
            size <<= 1
        self.size = size
        self.infinity = (1 << 60, 0, 0)
        self.values = [self.infinity] * (2 * size)

    def update(self, index: int, value: tuple[int, int, int]) -> None:
        position = self.size + index
        self.values[position] = value
        position >>= 1
        while position:
            self.values[position] = min(
                self.values[position << 1], self.values[(position << 1) | 1]
            )
            position >>= 1

    def query(self, start: int, stop: int) -> tuple[int, int, int]:
        """Return the minimum over the half-open interval [start, stop)."""
        if start >= stop:
            return self.infinity
        left = start + self.size
        right = stop + self.size
        result = self.infinity
        while left < right:
            if left & 1:
                result = min(result, self.values[left])
                left += 1
            if right & 1:
                right -= 1
                result = min(result, self.values[right])
            left >>= 1
            right >>= 1
        return result


def choose_packets(row: bytes, previous: bytes | None, bits: int) -> list[tuple[str, int]]:
    width = len(row)
    repeat_run = [1] * width
    copy_run = [0] * width

    for x in range(width - 1, -1, -1):
        if x + 1 < width and row[x] == row[x + 1]:
            repeat_run[x] = min(64, repeat_run[x + 1] + 1)
        if previous is not None and row[x] == previous[x]:
            copy_run[x] = 1
            if x + 1 < width:
                copy_run[x] = min(64, copy_run[x + 1] + 1)

    raw_tree = RangeMinTree(width + 1)
    literal_tree = RangeMinTree(width + 1)
    cost = [0] * (width + 1)
    choice: list[tuple[str, int] | None] = [None] * width

    raw_tree.update(width, (0, -width, width))
    literal_tree.update(width, (bits * width, -width, width))

    for x in range(width - 1, -1, -1):
        candidates: list[tuple[int, int, int, str, int]] = []

        literal_end = literal_tree.query(x + 1, min(width, x + 128) + 1)[2]
        literal_len = literal_end - x
        literal_cost = 8 + bits * literal_len + cost[literal_end]
        candidates.append((literal_cost, 2, -literal_len, "literal", literal_len))

        if repeat_run[x] >= 2:
            repeat_end = raw_tree.query(x + 2, x + repeat_run[x] + 1)[2]
            repeat_len = repeat_end - x
            candidates.append(
                (8 + bits + cost[repeat_end], 1, -repeat_len, "repeat", repeat_len)
            )

        if copy_run[x]:
            copy_end = raw_tree.query(x + 1, x + copy_run[x] + 1)[2]
            copy_len = copy_end - x
            candidates.append((8 + cost[copy_end], 0, -copy_len, "copy", copy_len))

        best = min(candidates)
        cost[x] = best[0]
        choice[x] = (best[3], best[4])
        raw_tree.update(x, (cost[x], -x, x))
        literal_tree.update(x, (cost[x] + bits * x, -x, x))

    packets: list[tuple[str, int]] = []
    x = 0
    while x < width:
        selected = choice[x]
        if selected is None:
            raise ArtworkError("packet optimizer did not cover the complete row")
        packets.append(selected)
        x += selected[1]
    return packets


def encode_row(row: bytes, previous: bytes | None, bits: int) -> tuple[bytes, int, int]:
    writer = BitWriter()
    x = 0
    packet_count = 0
    for operation, count in choose_packets(row, previous, bits):
        packet_count += 1
        if operation == "literal":
            writer.write(count - 1, 8)
            for index in row[x : x + count]:
                writer.write(index, bits)
        elif operation == "repeat":
            writer.write(0x80 | (count - 1), 8)
            writer.write(row[x], bits)
        elif operation == "copy":
            writer.write(0xC0 | (count - 1), 8)
        else:
            raise ArtworkError(f"unknown packet operation {operation}")
        x += count

    encoded, bit_count = writer.finish()
    if bit_count > 0xFFFF:
        raise ArtworkError(f"row requires {bit_count} encoded bits; maximum is 65535")
    record = bytearray(struct.pack("<H", bit_count))
    record.extend(encoded)
    record.extend(b"\x00" * (-len(record) % ROW_ALIGNMENT))
    return bytes(record), bit_count, packet_count


def decode_row(record: bytes, width: int, previous: bytes | None, bits: int) -> bytes:
    if len(record) < 2:
        raise ArtworkError("compressed row has no bit-count header")
    bit_count = struct.unpack_from("<H", record)[0]
    reader = BitReader(record[2:], bit_count)
    output = bytearray()

    while len(output) < width:
        header = reader.read(8)
        if not (header & 0x80):
            count = (header & 0x7F) + 1
            for _ in range(count):
                output.append(reader.read(bits))
        elif not (header & 0x40):
            count = (header & 0x3F) + 1
            output.extend([reader.read(bits)] * count)
        else:
            count = (header & 0x3F) + 1
            if previous is None:
                raise ArtworkError("first row contains a previous-row packet")
            start = len(output)
            output.extend(previous[start : start + count])

        if len(output) > width:
            raise ArtworkError("compressed row emits more pixels than its width")

    if reader.position != bit_count:
        raise ArtworkError(
            f"compressed row consumed {reader.position} of {bit_count} declared bits"
        )
    return bytes(output)


def parse_image_argument(value: str) -> tuple[int, Path]:
    for name, role in (("background=", ROLE_BACKGROUND), ("foreground=", ROLE_FOREGROUND)):
        if value.lower().startswith(name):
            return role, Path(value[len(name) :])
    return ROLE_BACKGROUND, Path(value)


def load_indexed_rgba(path: Path) -> tuple[int, int, bytes, bytes, int, bool]:
    if not path.is_file():
        raise ArtworkError(f"{path}: file does not exist")
    if path.suffix.lower() != ".png":
        raise ArtworkError(f"{path}: artwork input must be a PNG")

    try:
        with Image.open(path) as source:
            if source.format != "PNG" or source.mode != "P":
                raise ArtworkError(
                    f"{path}: artwork must be an indexed PNG (P mode)"
                )

            width, height = source.size
            source_palette = source.getpalette()
            if source_palette is None or len(source_palette) < 3:
                raise ArtworkError(f"{path}: indexed PNG has no color palette")

            alpha = [255] * 256
            transparency = source.info.get("transparency")
            if isinstance(transparency, int):
                if not 0 <= transparency < 256:
                    raise ArtworkError(f"{path}: invalid transparent palette index")
                alpha[transparency] = 0
            elif isinstance(transparency, (bytes, bytearray, list, tuple)):
                if len(transparency) > 256:
                    raise ArtworkError(f"{path}: transparency table is too large")
                for index, value in enumerate(transparency):
                    alpha[index] = int(value)
            elif transparency is not None:
                raise ArtworkError(f"{path}: unsupported indexed transparency data")

            remap: dict[int, int] = {}
            palette: list[tuple[int, int, int, int]] = []
            indices = bytearray()
            has_alpha = False

            for source_index in source.tobytes():
                index = remap.get(source_index)
                if index is None:
                    rgb_offset = source_index * 3
                    if rgb_offset + 2 >= len(source_palette):
                        raise ArtworkError(
                            f"{path}: pixel uses missing palette index {source_index}"
                        )
                    color = (
                        source_palette[rgb_offset],
                        source_palette[rgb_offset + 1],
                        source_palette[rgb_offset + 2],
                        alpha[source_index],
                    )
                    index = len(palette)
                    remap[source_index] = index
                    palette.append(color)
                    has_alpha |= color[3] != 255
                indices.append(index)
    except ArtworkError:
        raise
    except Exception as error:
        raise ArtworkError(f"{path}: cannot read PNG: {error}") from error

    color_count = len(palette)
    if color_count <= 16:
        bits = 4
    elif color_count <= 64:
        bits = 6
    else:
        bits = 8

    palette_entries = 1 << bits
    palette.extend([(0, 0, 0, 0)] * (palette_entries - len(palette)))
    palette_bytes = bytes(component for color in palette for component in color)
    return width, height, bytes(indices), palette_bytes, bits, has_alpha


def encode_plane(role: int, path: Path) -> dict[str, object]:
    width, height, pixels, palette, bits, has_alpha = load_indexed_rgba(path)
    payload = bytearray()
    row_stats = []
    previous: bytes | None = None

    for y in range(height):
        row = pixels[y * width : (y + 1) * width]
        record, encoded_bits, packet_count = encode_row(row, previous, bits)
        decoded = decode_row(record, width, previous, bits)
        if decoded != row:
            raise ArtworkError(f"{path}: row {y} failed encoder round-trip")
        payload.extend(record)
        row_stats.append(
            {
                "y": y,
                "raw_bytes": math.ceil(width * bits / 8),
                "encoded_bits": encoded_bits,
                "encoded_bytes": math.ceil(encoded_bits / 8),
                "stored_bytes": len(record),
                "packets": packet_count,
            }
        )
        previous = row

    decoded_rows = []
    offset = 0
    previous = None
    for y in range(height):
        if offset + 2 > len(payload):
            raise ArtworkError(f"{path}: serialized payload ends before row {y}")
        encoded_bits = struct.unpack_from("<H", payload, offset)[0]
        record_size = align(2 + math.ceil(encoded_bits / 8))
        record = bytes(payload[offset : offset + record_size])
        decoded = decode_row(record, width, previous, bits)
        decoded_rows.append(decoded)
        previous = decoded
        offset += record_size

    if offset != len(payload) or b"".join(decoded_rows) != pixels:
        raise ArtworkError(f"{path}: complete payload failed exact round-trip")

    return {
        "role": role,
        "path": path,
        "width": width,
        "height": height,
        "pixels": pixels,
        "palette": palette,
        "palette_entries": 1 << bits,
        "bits": bits,
        "has_alpha": has_alpha,
        "payload": bytes(payload),
        "rows": row_stats,
        "raw_bytes": math.ceil(width * height * bits / 8),
    }


def build_container(planes: list[dict[str, object]]) -> bytes:
    if not planes or len(planes) > 255:
        raise ArtworkError("VART requires between 1 and 255 planes")

    descriptor_offset = HEADER_SIZE
    cursor = align(HEADER_SIZE + DESCRIPTOR_SIZE * len(planes))
    palette_offsets: dict[bytes, int] = {}
    sections: list[tuple[int, bytes]] = []

    for plane in planes:
        palette = plane["palette"]
        assert isinstance(palette, bytes)
        if palette not in palette_offsets:
            palette_offsets[palette] = cursor
            sections.append((cursor, palette))
            cursor = align(cursor + len(palette))
        plane["palette_offset"] = palette_offsets[palette]

    for plane in planes:
        payload = plane["payload"]
        assert isinstance(payload, bytes)
        plane["payload_offset"] = cursor
        sections.append((cursor, payload))
        cursor = align(cursor + len(payload))

    total_size = cursor
    if total_size > MAX_CONTAINER_BYTES:
        raise ArtworkError(
            f"container is {total_size:,} bytes; maximum is {MAX_CONTAINER_BYTES:,}"
        )

    container = bytearray(total_size)
    layer_ids = sorted({int(plane["role"]) for plane in planes})
    header = struct.pack(
        "<4sBBBBIIIHHII32s",
        MAGIC,
        VERSION,
        0,
        len(layer_ids),
        len(planes),
        total_size,
        0,
        descriptor_offset,
        DESCRIPTOR_SIZE,
        0,
        0,
        0,
        b"\x00" * 32,
    )
    if len(header) != HEADER_SIZE:
        raise ArtworkError("internal error: VART header size is incorrect")
    container[:HEADER_SIZE] = header

    for index, plane in enumerate(planes):
        flags = 0x01
        if plane["has_alpha"]:
            flags |= 0x02
        descriptor = struct.pack(
            "<HHBBBBHHIIIIIIIII",
            int(plane["width"]),
            int(plane["height"]),
            int(plane["role"]),
            int(plane["role"]),
            int(plane["bits"]),
            flags,
            int(plane["palette_entries"]),
            0,
            int(plane["palette_offset"]),
            len(plane["palette"]),
            int(plane["payload_offset"]),
            len(plane["payload"]),
            int(plane["width"]) * int(plane["height"]),
            int(plane["height"]),
            0,
            0,
            0,
        )
        if len(descriptor) != DESCRIPTOR_SIZE:
            raise ArtworkError("internal error: VART descriptor size is incorrect")
        start = descriptor_offset + index * DESCRIPTOR_SIZE
        container[start : start + DESCRIPTOR_SIZE] = descriptor

    for offset, data in sections:
        container[offset : offset + len(data)] = data

    checksum = zlib.crc32(container[descriptor_offset:]) & 0xFFFFFFFF
    struct.pack_into("<I", container, 0x0C, checksum)
    return bytes(container)


def verify_container(container: bytes, planes: list[dict[str, object]]) -> None:
    if len(container) < HEADER_SIZE:
        raise ArtworkError("generated container is shorter than its header")
    (
        magic,
        version,
        flags,
        layer_count,
        plane_count,
        total_size,
        checksum,
        descriptor_offset,
        descriptor_size,
        reserved16,
        reserved0,
        reserved1,
        reserved_bytes,
    ) = struct.unpack_from("<4sBBBBIIIHHII32s", container)

    if magic != MAGIC or version != VERSION or total_size != len(container):
        raise ArtworkError("generated VART header failed verification")
    if flags or reserved16 or reserved0 or reserved1 or any(reserved_bytes):
        raise ArtworkError("generated VART header has non-zero reserved fields")
    if plane_count != len(planes) or descriptor_size != DESCRIPTOR_SIZE:
        raise ArtworkError("generated VART descriptor table failed verification")
    if layer_count != len({int(plane["role"]) for plane in planes}):
        raise ArtworkError("generated VART layer count failed verification")
    if zlib.crc32(container[descriptor_offset:]) & 0xFFFFFFFF != checksum:
        raise ArtworkError("generated VART checksum failed verification")

    occupied: list[tuple[int, int, str]] = []
    for index, expected in enumerate(planes):
        start = descriptor_offset + index * descriptor_size
        fields = struct.unpack_from("<HHBBBBHHIIIIIIIII", container, start)
        width, height, layer_id, role, bits, desc_flags = fields[:6]
        palette_entries = fields[6]
        palette_offset, palette_size, payload_offset, payload_size = fields[8:12]
        pixel_count, row_count, layout = fields[12:15]

        if (width, height, role, bits) != (
            expected["width"],
            expected["height"],
            expected["role"],
            expected["bits"],
        ):
            raise ArtworkError(f"generated descriptor {index} does not match its source")
        if layer_id != role or layout != 0 or not (desc_flags & 0x01):
            raise ArtworkError(f"generated descriptor {index} has invalid layer metadata")
        if palette_entries != expected["palette_entries"]:
            raise ArtworkError(f"generated descriptor {index} has invalid palette size")
        if pixel_count != width * height or row_count != height:
            raise ArtworkError(f"generated descriptor {index} has invalid dimensions")
        if palette_offset % 8 or payload_offset % 8:
            raise ArtworkError(f"generated descriptor {index} is not qword aligned")
        if palette_offset + palette_size > len(container):
            raise ArtworkError(f"generated descriptor {index} palette is out of range")
        if payload_offset + payload_size > len(container):
            raise ArtworkError(f"generated descriptor {index} payload is out of range")

        occupied.append((payload_offset, payload_offset + payload_size, f"payload {index}"))
        payload = container[payload_offset : payload_offset + payload_size]
        decoded_rows = []
        previous = None
        offset = 0
        for y in range(height):
            if offset + 2 > len(payload):
                raise ArtworkError(f"generated payload {index} ends before row {y}")
            encoded_bits = struct.unpack_from("<H", payload, offset)[0]
            record_size = align(2 + math.ceil(encoded_bits / 8))
            record = payload[offset : offset + record_size]
            decoded = decode_row(record, width, previous, bits)
            decoded_rows.append(decoded)
            previous = decoded
            offset += record_size
        if offset != payload_size or b"".join(decoded_rows) != expected["pixels"]:
            raise ArtworkError(f"generated payload {index} failed serialized round-trip")

    for left, right, name in sorted(occupied):
        if left < HEADER_SIZE or right > len(container) or left >= right:
            raise ArtworkError(f"generated {name} has an invalid range")


def validate_plane_set(planes: list[dict[str, object]], mra: Path) -> None:
    seen: set[tuple[int, int, int]] = set()
    for plane in planes:
        key = (int(plane["role"]), int(plane["width"]), int(plane["height"]))
        if key in seen:
            raise ArtworkError(
                f"duplicate {ROLE_NAMES[key[0]]} plane with dimensions {key[1]}x{key[2]}"
            )
        seen.add(key)

    try:
        root = ET.parse(mra).getroot()
    except Exception as error:
        raise ArtworkError(f"{mra}: cannot parse MRA XML: {error}") from error
    setname = (root.findtext("setname") or "").strip().lower()
    if setname == "astdelux":
        actual = {
            (int(plane["width"]), int(plane["height"]))
            for plane in planes
            if int(plane["role"]) == ROLE_BACKGROUND
        }
        if actual != ASTEROIDS_PLANES:
            missing = sorted(ASTEROIDS_PLANES - actual)
            extra = sorted(actual - ASTEROIDS_PLANES)
            details = []
            if missing:
                details.append("missing " + ", ".join(f"{w}x{h}" for w, h in missing))
            if extra:
                details.append("unsupported " + ", ".join(f"{w}x{h}" for w, h in extra))
            raise ArtworkError(
                "Asteroids Deluxe requires exactly four background planes: "
                + "; ".join(details)
            )


def format_xml_part(container: bytes) -> str:
    hexadecimal = container.hex().upper()
    lines = [hexadecimal[index : index + 128] for index in range(0, len(hexadecimal), 128)]
    md5 = hashlib.md5(container).hexdigest()
    body = "\n".join(f"\t\t{line}" for line in lines)
    return f'<rom index="{ROM_INDEX}" md5="{md5}">\n\t<part>\n{body}\n\t</part>\n</rom>\n'


def next_art_mra_path(mra: Path) -> Path:
    counter = 0
    while True:
        suffix = "" if counter == 0 else str(counter)
        candidate = mra.with_name(f"{mra.stem}_art{suffix}{mra.suffix}")
        if not candidate.exists():
            return candidate
        counter += 1


def write_mra(source: Path, destination: Path, container: bytes) -> None:
    parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
    try:
        tree = ET.parse(source, parser=parser)
    except Exception as error:
        raise ArtworkError(f"{source}: cannot parse MRA XML: {error}") from error
    root = tree.getroot()
    matching = [
        child
        for child in root
        if child.tag == "rom" and child.get("index") == str(ROM_INDEX)
    ]
    if len(matching) > 1:
        raise ArtworkError(f"{source}: contains more than one ROM index {ROM_INDEX}")
    for child in matching:
        root.remove(child)

    rom = ET.Element(
        "rom",
        {
            "index": str(ROM_INDEX),
            "md5": hashlib.md5(container).hexdigest(),
        },
    )
    part = ET.SubElement(rom, "part")
    hexadecimal = container.hex().upper()
    lines = [hexadecimal[index : index + 128] for index in range(0, len(hexadecimal), 128)]
    part.text = "\n" + "\n".join(lines) + "\n"

    children = list(root)
    rom0_position = next(
        (
            index
            for index, child in enumerate(children)
            if child.tag == "rom" and child.get("index") == "0"
        ),
        None,
    )
    if rom0_position is None:
        raise ArtworkError(f"{source}: has no primary ROM index 0")
    root.insert(rom0_position + 1, rom)
    ET.indent(tree, space="\t")

    destination.parent.mkdir(parents=True, exist_ok=True)
    file_descriptor, temporary_name = tempfile.mkstemp(
        prefix=destination.name + ".", suffix=".tmp", dir=destination.parent
    )
    os.close(file_descriptor)
    temporary = Path(temporary_name)
    try:
        tree.write(temporary, encoding="unicode", xml_declaration=False)
        ET.parse(temporary)
        temporary.replace(destination)
    finally:
        if temporary.exists():
            temporary.unlink()


def build_stats(planes: list[dict[str, object]], container: bytes) -> dict[str, object]:
    plane_reports = []
    all_rows = []
    for plane in planes:
        rows = sorted(plane["rows"], key=lambda row: row["stored_bytes"], reverse=True)
        report = {
            "file": str(plane["path"]),
            "role": ROLE_NAMES[int(plane["role"])],
            "width": plane["width"],
            "height": plane["height"],
            "index_bits": plane["bits"],
            "palette_entries": plane["palette_entries"],
            "has_alpha": plane["has_alpha"],
            "raw_bytes": plane["raw_bytes"],
            "compressed_bytes": len(plane["payload"]),
            "ratio": len(plane["payload"]) / int(plane["raw_bytes"]),
            "worst_rows": rows[:3],
        }
        plane_reports.append(report)
        for row in rows:
            all_rows.append(
                {
                    "file": str(plane["path"]),
                    "width": plane["width"],
                    "height": plane["height"],
                    **row,
                }
            )

    return {
        "format": "VART",
        "version": VERSION,
        "round_trip": "exact",
        "container_bytes": len(container),
        "xml_hex_characters": len(container) * 2,
        "planes": plane_reports,
        "global_worst_rows": sorted(
            all_rows, key=lambda row: row["stored_bytes"], reverse=True
        )[:3],
    }


def print_stats(stats: dict[str, object]) -> None:
    print("VART build complete")
    print(f"  exact round-trip: {stats['round_trip']}")
    for plane in stats["planes"]:
        ratio = 100.0 * float(plane["ratio"])
        alpha = "yes" if plane["has_alpha"] else "no"
        print(
            f"  {plane['width']}x{plane['height']} {plane['role']}: "
            f"{plane['index_bits']}-bit, alpha={alpha}, "
            f"raw={plane['raw_bytes']:,}, compressed={plane['compressed_bytes']:,} "
            f"({ratio:.2f}%)"
        )
        for row in plane["worst_rows"]:
            print(
                f"    row {row['y']:4d}: raw={row['raw_bytes']:,}, "
                f"encoded={row['encoded_bytes']:,}, stored={row['stored_bytes']:,}, "
                f"packets={row['packets']}"
            )
    print(f"  container: {stats['container_bytes']:,} bytes")
    print(f"  MRA hexadecimal: {stats['xml_hex_characters']:,} characters")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate PNG artwork, build a VART package, and embed ROM index 2."
    )
    parser.add_argument(
        "mra",
        type=Path,
        help="source MRA used to create a suffixed artwork MRA",
    )
    parser.add_argument(
        "images",
        nargs="+",
        help="PNG files; prefix with background= or foreground= to set the layer role",
    )
    parser.add_argument(
        "--no-update-mra",
        action="store_true",
        help="build and validate outputs without writing a generated MRA",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    mra = arguments.mra.resolve()
    if not mra.is_file():
        raise ArtworkError(f"{mra}: MRA file does not exist")

    sources = [parse_image_argument(value) for value in arguments.images]
    planes = [encode_plane(role, path.resolve()) for role, path in sources]
    planes.sort(key=lambda plane: (int(plane["role"]), -int(plane["height"]), -int(plane["width"])))
    validate_plane_set(planes, mra)
    container = build_container(planes)
    verify_container(container, planes)
    stats = build_stats(planes, container)

    generated = Path(__file__).resolve().parent / "generated"
    generated.mkdir(parents=True, exist_ok=True)
    stem = mra.stem.replace(" ", "_").lower()
    (generated / f"{stem}.vart").write_bytes(container)
    xml_part = generated / "rom_index_2.xml"
    xml_part.write_text(
        format_xml_part(container), encoding="ascii", newline="\n"
    )
    (generated / "artwork_stats.json").write_text(
        json.dumps(stats, indent=2) + "\n", encoding="ascii", newline="\n"
    )

    output_mra = None
    if not arguments.no_update_mra:
        output_mra = next_art_mra_path(mra)
        write_mra(mra, output_mra, container)
    print_stats(stats)
    print(f"  binary: {generated / f'{stem}.vart'}")
    print(f"  XML part: {xml_part}")
    print(f"  statistics: {generated / 'artwork_stats.json'}")
    if arguments.no_update_mra:
        print(f"  source MRA: unchanged at {mra}")
        print("  generated MRA: not written (--no-update-mra)")
    else:
        print(f"  source MRA: unchanged at {mra}")
        print(f"  generated MRA: {output_mra}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ArtworkError as error:
        raise SystemExit(f"ERROR: {error}") from error
