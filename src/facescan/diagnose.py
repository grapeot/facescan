"""Diagnose a scan's pose quality before trusting it for fusion.

The camera pose from ARKit face tracking has proven unreliable on device: it can
report large rotation with almost no translation, which is geometrically
inconsistent with a face that stays centred at ~0.3 m. This tool reports the
evidence so a human or agent can decide whether to trust ARKit poses, use the
face-anchor frame, or fall back to ICP.

Run: python -m facescan diagnose <scan_dir>
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

from facescan.contract import FrameMeta, load_depth, load_scan


def _rotation_deg(a: np.ndarray, b: np.ndarray) -> float:
    r = a[:3, :3].T @ b[:3, :3]
    c = float(np.clip((np.trace(r) - 1.0) / 2.0, -1.0, 1.0))
    return float(np.degrees(np.arccos(c)))


def _face_center_world(scan_dir: Path, frame: FrameMeta, pose: np.ndarray) -> np.ndarray:
    """World position of the image centre pixel, using observed depth."""
    depth = load_depth(scan_dir, frame)
    k = frame.intrinsics
    h, w = depth.shape
    cy, cx = h // 2, w // 2
    z = float(depth[cy, cx])
    if not np.isfinite(z) or z <= 0:
        valid = depth[(depth > 0.15) & (depth < 0.6)]
        z = float(np.median(valid)) if valid.size else float("nan")
    x = (cx - k[0, 2]) * z / k[0, 0]
    y = (cy - k[1, 2]) * z / k[1, 1]
    cam_gl = np.array([x, -y, -z, 1.0])  # CV -> GL
    return (pose @ cam_gl)[:3]


def diagnose(scan_dir: Path) -> dict:
    scan_dir = Path(scan_dir)
    scan = load_scan(scan_dir)
    frames = scan.frames
    if len(frames) < 2:
        return {"error": "need at least 2 frames", "num_frames": len(frames)}

    poses = [f.pose for f in frames]
    trans = np.array([p[:3, 3] for p in poses])
    centers = np.array([_face_center_world(scan_dir, f, f.pose) for f in frames])

    result = {
        "num_frames": len(frames),
        "world_tracking_enabled": scan.world_tracking_enabled,
        "arkit_total_rotation_deg": round(_rotation_deg(poses[0], poses[-1]), 1),
        "arkit_translation_span_m": round(float(np.linalg.norm(trans.max(0) - trans.min(0))), 3),
        "face_center_world_spread_m": round(float(np.linalg.norm(centers.max(0) - centers.min(0))), 3),
        "face_center_max_dev_m": round(
            float(np.linalg.norm(centers - np.nanmean(centers, 0), axis=1).max()), 3
        ),
    }

    if all(f.face_pose is not None for f in frames):
        face_pos = np.array([f.face_pose[:3, 3] for f in frames])
        face_rot = max(_rotation_deg(frames[0].face_pose, f.face_pose) for f in frames)
        result["face_anchor_translation_span_m"] = round(
            float(np.linalg.norm(face_pos.max(0) - face_pos.min(0))), 3
        )
        result["face_anchor_max_rotation_deg"] = round(float(face_rot), 1)

    # Heuristic verdict: a still subject should keep the face centre roughly fixed.
    result["verdict"] = (
        "ARKit pose looks metric-consistent"
        if result["face_center_max_dev_m"] < 0.05
        else "ARKit pose INCONSISTENT with depth; do not fuse directly"
    )
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="facescan diagnose")
    parser.add_argument("scan_dir", type=Path)
    args = parser.parse_args(argv)
    print(json.dumps(diagnose(args.scan_dir), indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
