#!/usr/bin/env python3
"""Measure static-grid geometry and brightness in a capture-card recording."""

import argparse
import csv
import hashlib
import json
from pathlib import Path

import cv2
import numpy as np
from scipy.signal import find_peaks


def spectral_peaks(values, fps, count=5):
    values = np.asarray(values, dtype=np.float64)
    values -= np.mean(values)
    if len(values) < 4 or np.std(values) == 0:
        return []
    windowed = values * np.hanning(len(values))
    power = np.abs(np.fft.rfft(windowed)) ** 2
    freq = np.fft.rfftfreq(len(values), 1.0 / fps)
    power[0] = 0
    order = np.argsort(power)[::-1]
    return [
        {"hz": float(freq[i]), "relative_power": float(power[i] / power[order[0]])}
        for i in order[:count]
    ]


def ridge_positions(profile, expected, radius=3):
    positions = []
    strengths = []
    for center in expected:
        lo = max(0, int(round(center)) - radius)
        hi = min(len(profile), int(round(center)) + radius + 1)
        x = np.arange(lo, hi, dtype=np.float64)
        weights = profile[lo:hi].astype(np.float64)
        weights -= np.percentile(weights, 10)
        weights = np.maximum(weights, 0)
        total = weights.sum()
        if total <= 0:
            positions.append(float(center))
            strengths.append(0.0)
        else:
            positions.append(float(np.dot(x, weights) / total))
            strengths.append(float(total))
    return np.asarray(positions), np.asarray(strengths)


def fit_axis(expected, measured, strengths):
    good = strengths > np.percentile(strengths, 25)
    if np.count_nonzero(good) < 3:
        good = np.ones_like(strengths, dtype=bool)
    origin = np.mean(expected[good])
    design = np.column_stack((np.ones(np.count_nonzero(good)), expected[good] - origin))
    offset, scale_delta = np.linalg.lstsq(
        design, measured[good] - expected[good], rcond=None
    )[0]
    residual = measured[good] - expected[good] - offset - scale_delta * (expected[good] - origin)
    return float(offset), float(scale_delta), float(np.sqrt(np.mean(residual ** 2)))


def detect_grid(mean_frame):
    threshold = max(8.0, float(np.percentile(mean_frame, 99.0)) * 0.18)
    ys, xs = np.nonzero(mean_frame >= threshold)
    if len(xs) < 100:
        raise RuntimeError("could not locate bright grid pixels")
    x0, x1 = np.percentile(xs, [1, 99]).astype(int)
    y0, y1 = np.percentile(ys, [1, 99]).astype(int)
    pad = 12
    x0, x1 = max(0, x0 - pad), min(mean_frame.shape[1] - 1, x1 + pad)
    y0, y1 = max(0, y0 - pad), min(mean_frame.shape[0] - 1, y1 + pad)
    roi = mean_frame[y0:y1 + 1, x0:x1 + 1]
    xp = roi.sum(axis=0)
    yp = roi.sum(axis=1)
    xpeaks, _ = find_peaks(xp, distance=8, prominence=max(1.0, np.max(xp) * 0.025))
    ypeaks, _ = find_peaks(yp, distance=8, prominence=max(1.0, np.max(yp) * 0.025))
    # Keep the strongest regular grid ridges; short labels/ticks are rejected by prominence.
    xpeaks = xpeaks[xp[xpeaks] >= np.percentile(xp[xpeaks], 35)]
    ypeaks = ypeaks[yp[ypeaks] >= np.percentile(yp[ypeaks], 35)]
    return (x0, y0, x1 + 1, y1 + 1), xpeaks.astype(float), ypeaks.astype(float)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("video", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--discard-seconds", type=float, default=5.0)
    args = parser.parse_args()

    cap = cv2.VideoCapture(str(args.video))
    fps = float(cap.get(cv2.CAP_PROP_FPS))
    if fps <= 0:
        raise RuntimeError("capture has no usable frame rate")
    discard = int(round(args.discard_seconds * fps))

    mean_frame = None
    kept = 0
    index = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        if index >= discard:
            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY).astype(np.float64)
            if mean_frame is None:
                mean_frame = np.zeros_like(gray)
            kept += 1
            mean_frame += (gray - mean_frame) / kept
        index += 1
    cap.release()
    if kept == 0:
        raise RuntimeError("no frames remain after discard interval")

    roi_box, xpeaks, ypeaks = detect_grid(mean_frame)
    x0, y0, x1, y1 = roi_box
    if len(xpeaks) < 4 or len(ypeaks) < 4:
        raise RuntimeError(f"too few grid ridges: {len(xpeaks)} vertical, {len(ypeaks)} horizontal")

    rows = []
    hashes = []
    cap = cv2.VideoCapture(str(args.video))
    number = 0
    while True:
        ok, color = cap.read()
        if not ok:
            break
        if number < discard:
            number += 1
            continue
        frame = cv2.cvtColor(color, cv2.COLOR_BGR2GRAY)
        roi = frame[y0:y1, x0:x1]
        xp = roi.astype(np.float64).sum(axis=0)
        yp = roi.astype(np.float64).sum(axis=1)
        xpos, xstrength = ridge_positions(xp, xpeaks)
        ypos, ystrength = ridge_positions(yp, ypeaks)
        xoff, xscale, xrms = fit_axis(xpeaks, xpos, xstrength)
        yoff, yscale, yrms = fit_axis(ypeaks, ypos, ystrength)
        digest = hashlib.sha256(frame.tobytes()).hexdigest()
        hashes.append(digest)
        rows.append({
            "frame": number,
            "time_s": number / fps,
            "brightness_sum": int(np.sum(roi, dtype=np.int64)),
            "lit_pixels": int(np.count_nonzero(roi >= 16)),
            "x_offset_px": xoff,
            "y_offset_px": yoff,
            "x_scale_delta": xscale,
            "y_scale_delta": yscale,
            "x_local_rms_px": xrms,
            "y_local_rms_px": yrms,
            "sha256_luma": digest,
        })
        number += 1
    cap.release()

    args.out.mkdir(parents=True, exist_ok=True)
    csv_path = args.out / "frames.csv"
    with csv_path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)

    metrics = ("brightness_sum", "lit_pixels", "x_offset_px", "y_offset_px",
               "x_scale_delta", "y_scale_delta", "x_local_rms_px", "y_local_rms_px")
    summary = {
        "video": str(args.video),
        "fps": fps,
        "decoded_frames": index,
        "discarded_frames": discard,
        "analyzed_frames": len(rows),
        "analyzed_seconds": len(rows) / fps,
        "roi_xyxy": [int(value) for value in roi_box],
        "vertical_ridges": [float(x0 + x) for x in xpeaks],
        "horizontal_ridges": [float(y0 + y) for y in ypeaks],
        "unique_luma_frames": len(set(hashes)),
        "metrics": {},
    }
    for metric in metrics:
        values = np.asarray([row[metric] for row in rows], dtype=np.float64)
        summary["metrics"][metric] = {
            "mean": float(np.mean(values)),
            "std": float(np.std(values)),
            "min": float(np.min(values)),
            "max": float(np.max(values)),
            "p05": float(np.percentile(values, 5)),
            "p95": float(np.percentile(values, 95)),
            "spectral_peaks": spectral_peaks(values, fps),
        }
    summary_path = args.out / "summary.json"
    summary_path.write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
