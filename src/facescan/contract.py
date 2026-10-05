"""Frozen iPhone <-> Mac contract.

This module is the single implementation of the data contract described in
`docs/rfc.md` section 3. The iOS app writes this format; the Mac pipeline reads
it. Changing either side requires changing this file and the RFC together.

Depth on disk: raw little-endian Float32, metres, row-major, no padding.
Pose: ARKit `camera.transform`, camera->world, right-handed, camera looks -Z.
Intrinsics: 3x3 row-major, already scaled to the *depth* resolution.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional

import numpy as np

SCHEMA_VERSION = 1
DEPTH_DTYPE = "<f4"  # little-endian float32, metres
STATUS_FILENAME = "status.json"
META_FILENAME = "meta.json"

# A frame's depth map is smaller than the colour image; the depth intrinsics in
# meta.json are already scaled to the depth resolution, so reconstruct must use
# depth_width/depth_height for both the depth array and the camera matrix.


@dataclass
class FrameMeta:
    index: int
    timestamp: float
    pose: np.ndarray          # (4, 4) camera->world, ARKit convention
    intrinsics: np.ndarray    # (3, 3) depth-resolution camera matrix
    depth_width: int
    depth_height: int
    color_width: int
    color_height: int
    depth_file: str
    color_file: str
    confidence: float = 1.0
    face_pose: Optional[np.ndarray] = None  # (4, 4) face->world, ARKit convention

    @property
    def pose_4x4(self) -> np.ndarray:
        return self.pose


@dataclass
class ScanMeta:
    run_id: str
    device_model: str
    frames: List[FrameMeta]
    schema_version: int = SCHEMA_VERSION
    world_tracking_enabled: bool = False


@dataclass
class ScanStatus:
    run_id: str
    state: str                # idle | recording | stopped
    keyframes: int
    depth_missing: int
    depth_total: int
    updated_at: float
    schema_version: int = SCHEMA_VERSION

    @property
    def is_stopped(self) -> bool:
        return self.state == "stopped"


def _as_matrix(flat: List[float], rows: int, cols: int) -> np.ndarray:
    arr = np.asarray(flat, dtype=np.float64)
    if arr.size != rows * cols:
        raise ValueError(f"expected {rows * cols} values, got {arr.size}")
    return arr.reshape(rows, cols)


def load_scan(scan_dir: Path) -> ScanMeta:
    """Load `meta.json` from a scan directory."""
    path = Path(scan_dir) / META_FILENAME
    if not path.exists():
        raise FileNotFoundError(f"no {META_FILENAME} in {scan_dir}")
    raw = json.loads(path.read_text())
    frames = []
    for f in raw["frames"]:
        face_pose = f.get("face_pose")
        frames.append(
            FrameMeta(
                index=f["index"],
                timestamp=f["timestamp"],
                pose=_as_matrix(f["pose"], 4, 4),
                intrinsics=_as_matrix(f["intrinsics"], 3, 3),
                depth_width=f["depth_width"],
                depth_height=f["depth_height"],
                color_width=f.get("color_width", 0),
                color_height=f.get("color_height", 0),
                depth_file=f["depth_file"],
                color_file=f.get("color_file", ""),
                confidence=f.get("confidence", 1.0),
                face_pose=_as_matrix(face_pose, 4, 4) if face_pose else None,
            )
        )
    return ScanMeta(
        run_id=raw.get("run_id", ""),
        device_model=raw.get("device_model", "unknown"),
        frames=frames,
        schema_version=raw.get("schema_version", SCHEMA_VERSION),
        world_tracking_enabled=raw.get("world_tracking_enabled", False),
    )


def load_status(documents_dir: Path, run_id: Optional[str] = None) -> ScanStatus:
    """Load `status.json`. If run_id is given, require it to match."""
    path = Path(documents_dir) / STATUS_FILENAME
    if not path.exists():
        raise FileNotFoundError(f"no {STATUS_FILENAME} in {documents_dir}")
    raw = json.loads(path.read_text())
    if run_id is not None and raw.get("run_id") not in (run_id, ""):
        raise ValueError(
            f"status run_id {raw.get('run_id')!r} != requested {run_id!r}"
        )
    return ScanStatus(
        run_id=raw.get("run_id", ""),
        state=raw.get("state", "idle"),
        keyframes=raw.get("keyframes", 0),
        depth_missing=raw.get("depth_missing", 0),
        depth_total=raw.get("depth_total", 0),
        updated_at=raw.get("updated_at", 0.0),
        schema_version=raw.get("schema_version", SCHEMA_VERSION),
    )


def load_depth(scan_dir: Path, frame: FrameMeta) -> np.ndarray:
    """Read a frame's raw Float32 depth into a (h, w) float32 array in metres."""
    path = Path(scan_dir) / frame.depth_file
    flat = np.fromfile(path, dtype=DEPTH_DTYPE)
    expected = frame.depth_width * frame.depth_height
    if flat.size != expected:
        raise ValueError(
            f"{frame.depth_file}: expected {expected} floats "
            f"({frame.depth_width}x{frame.depth_height}), got {flat.size}"
        )
    return flat.reshape(frame.depth_height, frame.depth_width)


def intrinsics_from_flat(flat: List[float]) -> np.ndarray:
    """3x3 row-major intrinsics from the flat 9-value form stored in meta.json."""
    return _as_matrix(flat, 3, 3)


def arkit_pose_to_extrinsic(pose_cam_to_world: np.ndarray) -> np.ndarray:
    """Convert an ARKit camera->world pose to an Open3D world->camera extrinsic.

    ARKit/GL camera convention: right-handed, +X right, +Y up, camera looks -Z.
    OpenCV/Open3D camera convention: right-handed, +X right, +Y down, camera
    looks +Z. The flip matrix diag(1, -1, -1) maps GL camera coords to CV camera
    coords; composing with the inverse gives world->camera in CV convention,
    which is what Open3D's TSDF integrate expects.
    """
    pose = np.asarray(pose_cam_to_world, dtype=np.float64).reshape(4, 4)
    gl_to_cv = np.diag([1.0, -1.0, -1.0, 1.0])
    return gl_to_cv @ np.linalg.inv(pose)
