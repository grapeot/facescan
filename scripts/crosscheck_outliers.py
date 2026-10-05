#!/usr/bin/env python3
"""Cross-check the outlier gate against an independent depth-consistency signal.

The production gate (`facescan.reconstruct._reject_inconsistent_frames`) decides
frame quality from the face-centre position *derived from the frame's own pose*.
That is convenient but partly circular: it trusts the same pose it is judging.

This script computes a different, pose-independent-per-frame signal: for each
consecutive pair, take frame i's depth points, transform them into frame i+1 via
the ARKit relative pose, and measure how well they reproject onto frame i+1's
observed depth. A frame with a spurious pose disagrees with BOTH neighbours.

It then prints the gate's keep/drop decision next to this independent signal so a
human can see whether the gate is catching the genuinely bad frames.

Usage: python scripts/crosscheck_outliers.py <scan_dir> [--depth-min 0.2] [--depth-max 0.5]
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from facescan.contract import load_depth, load_scan  # noqa: E402
from facescan.reconstruct import _reject_inconsistent_frames  # noqa: E402


def _reproject_error(a, b, da, db, depth_min, depth_max, step=20):
    """Median |depth error| reprojecting frame a's points into frame b.

    Works in CV camera space throughout: back-project a point in frame a, lift it
    to the world with frame a's pose (GL convention), drop it back into frame b,
    and compare the predicted CV Z against frame b's observed depth.
    """
    ka, kb = a.intrinsics, b.intrinsics
    flip = np.array([1, -1, -1, 1.0])
    h, w = da.shape
    errs = []
    for v in range(40, h - 40, step):
        for u in range(40, w - 40, step):
            z = da[v, u]
            if not (depth_min < z < depth_max) or not np.isfinite(z):
                continue
            x = (u - ka[0, 2]) * z / ka[0, 0]
            y = (v - ka[1, 2]) * z / ka[1, 1]
            world = a.pose @ (np.array([x, y, z, 1.0]) * flip)   # CV -> GL -> world
            cam_b = (np.linalg.inv(b.pose) @ world) * flip       # world -> GL -> CV
            if cam_b[2] <= 0:
                errs.append(1.0)
                continue
            uu = kb[0, 0] * cam_b[0] / cam_b[2] + kb[0, 2]
            vv = kb[1, 1] * cam_b[1] / cam_b[2] + kb[1, 2]
            ui, vi = int(round(uu)), int(round(vv))
            if 0 <= ui < w and 0 <= vi < h:
                zo = db[vi, ui]
                if depth_min < zo < depth_max:
                    errs.append(abs(zo - cam_b[2]))
    return float(np.median(errs)) if errs else float("nan")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("scan_dir", type=Path)
    ap.add_argument("--depth-min", type=float, default=0.2)
    ap.add_argument("--depth-max", type=float, default=0.5)
    args = ap.parse_args()

    scan = load_scan(args.scan_dir)
    frames = scan.frames
    depths = {
        f.index: load_depth(args.scan_dir, f) for f in frames
    }
    masked = {
        i: np.where((d > args.depth_min) & (d < args.depth_max) & np.isfinite(d), d, 0).astype(np.float32)
        for i, d in depths.items()
    }

    keep = _reject_inconsistent_frames(frames, masked, args.depth_min, args.depth_max)

    # Independent signal: for each frame, min of (err with prev, err with next).
    # A bad frame disagrees with both neighbours, so its min stays large.
    pair_err = {}
    for i in range(1, len(frames)):
        a, b = frames[i - 1], frames[i]
        e = _reproject_error(a, b, depths[a.index], depths[b.index], args.depth_min, args.depth_max)
        pair_err[(a.index, b.index)] = e

    print(f"{'frame':>5} {'gate':>6} {'err_vs_prev':>12} {'err_vs_next':>12} {'min_err':>8}")
    for idx, f in enumerate(frames):
        e_prev = pair_err.get((frames[idx - 1].index, f.index), float("nan")) if idx > 0 else float("nan")
        e_next = pair_err.get((f.index, frames[idx + 1].index), float("nan")) if idx < len(frames) - 1 else float("nan")
        mins = [e for e in (e_prev, e_next) if np.isfinite(e)]
        min_err = min(mins) if mins else float("nan")
        decision = "keep" if f.index in keep else "DROP"
        print(f"{f.index:>5} {decision:>6} {e_prev:>12.3f} {e_next:>12.3f} {min_err:>8.3f}")

    dropped = sorted(set(range(len(frames))) - keep)
    print(f"\ngate dropped: {dropped}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
