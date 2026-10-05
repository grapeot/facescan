"""Synthetic two-view plane fusion. A wrong GL→CV flip makes the views disagree."""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from facescan.reconstruct import reconstruct

PLANE_Z = 0.45
WIDTH = 48
HEIGHT = 36
FX = FY = 40.0
CX = (WIDTH - 1) / 2.0
CY = (HEIGHT - 1) / 2.0


def _intrinsics() -> np.ndarray:
    return np.array(
        [[FX, 0.0, CX], [0.0, FY, CY], [0.0, 0.0, 1.0]],
        dtype=np.float64,
    )


def _look_at(eye: np.ndarray, target: np.ndarray) -> np.ndarray:
    forward = target - eye
    forward = forward / np.linalg.norm(forward)
    backward = -forward
    up = np.array([0.0, 1.0, 0.0])
    right = np.cross(up, backward)
    right = right / np.linalg.norm(right)
    cam_up = np.cross(backward, right)
    pose = np.eye(4)
    pose[:3, :3] = np.column_stack([right, cam_up, backward])
    pose[:3, 3] = eye
    return pose


def _plane_depth(pose: np.ndarray, plane_z: float) -> np.ndarray:
    """OpenCV Z-depth of the world plane z=plane_z, independent of contract.py."""
    rotation = pose[:3, :3]
    translation = pose[:3, 3]
    us = np.arange(WIDTH, dtype=np.float64)
    vs = np.arange(HEIGHT, dtype=np.float64)
    uu, vv = np.meshgrid(us, vs)
    ray = np.stack(
        [(uu - CX) / FX, -((vv - CY) / FY), -np.ones_like(uu)],
        axis=-1,
    )
    denom = ray @ rotation[2]
    depth = np.full((HEIGHT, WIDTH), np.nan, dtype=np.float32)
    ok = np.abs(denom) > 1e-8
    depth[ok] = ((plane_z - translation[2]) / denom[ok]).astype(np.float32)
    depth[~np.isfinite(depth) | (depth <= 0)] = 0
    return depth


def _write_scan(scan_dir: Path, frames: list[tuple[np.ndarray, np.ndarray]]) -> None:
    meta_frames = []
    intrinsics = _intrinsics()
    for index, (pose, depth) in enumerate(frames):
        name = f"depth_{index:04d}.bin"
        np.ascontiguousarray(depth, dtype="<f4").tofile(scan_dir / name)
        meta_frames.append(
            {
                "index": index,
                "timestamp": float(index),
                "pose": pose.reshape(-1).tolist(),
                "intrinsics": intrinsics.reshape(-1).tolist(),
                "depth_width": WIDTH,
                "depth_height": HEIGHT,
                "color_width": 0,
                "color_height": 0,
                "depth_file": name,
                "color_file": "",
                "confidence": 1.0,
            }
        )
    (scan_dir / "meta.json").write_text(
        json.dumps(
            {
                "schema_version": 1,
                "run_id": "synthetic",
                "device_model": "synthetic",
                "frames": meta_frames,
            }
        )
    )


def test_two_views_of_one_plane_fuse_thin(tmp_path: Path) -> None:
    eye_a = np.array([0.0, 0.0, 0.15])
    eye_b = np.array([0.06, 0.03, 0.18])
    target = np.array([0.0, 0.0, PLANE_Z])
    scan_dir = tmp_path / "scan"
    scan_dir.mkdir()
    _write_scan(
        scan_dir,
        [
            (_look_at(eye_a, target), _plane_depth(_look_at(eye_a, target), PLANE_Z)),
            (_look_at(eye_b, target), _plane_depth(_look_at(eye_b, target), PLANE_Z)),
        ],
    )
    out_path = tmp_path / "plane.ply"
    stats = reconstruct(
        scan_dir,
        out_path,
        voxel_size=0.004,
        sdf_trunc=0.016,
        depth_min=0.15,
        depth_max=0.60,
    )

    assert out_path.is_file() and out_path.stat().st_size > 0
    assert set(stats) == {
        "frame",
        "num_frames",
        "num_candidates",
        "num_skipped",
        "num_vertices",
        "num_triangles",
        "out_path",
    }
    assert stats["num_frames"] == 2
    assert stats["num_vertices"] > 0
    assert stats["num_triangles"] > 0
    assert stats["out_path"] == str(out_path)

    import open3d as o3d

    mesh = o3d.io.read_triangle_mesh(str(out_path))
    verts = np.asarray(mesh.vertices)
    assert verts.shape[0] > 0
    dist = np.abs(verts[:, 2] - PLANE_Z)
    assert float(np.median(dist)) < 0.008
    assert float(np.mean(dist < 0.012)) > 0.9
    assert float(verts[:, 0].max() - verts[:, 0].min()) > 0.05


def test_spurious_pose_frame_is_rejected(tmp_path: Path) -> None:
    """A frame whose pose places the face far from the cluster must be dropped."""
    scan_dir = tmp_path / "spike"
    scan_dir.mkdir()
    target = np.array([0.0, 0.0, PLANE_Z])
    eyes = [np.array([0.0, 0.0, 0.15]), np.array([0.03, 0.01, 0.16]), np.array([0.05, -0.01, 0.17])]
    frames = [(_look_at(e, target), _plane_depth(_look_at(e, target), PLANE_Z)) for e in eyes]
    # A fourth "bad" frame: same depth, but a pose that puts the camera somewhere
    # physically inconsistent with the rest (a re-localisation spike).
    spike_pose = np.eye(4)
    spike_pose[:3, 3] = [0.5, 0.5, 0.5]
    frames.append((spike_pose, _plane_depth(_look_at(eyes[0], target), PLANE_Z)))
    _write_scan(scan_dir, frames)

    stats = reconstruct(
        scan_dir, tmp_path / "spike.ply", voxel_size=0.004, sdf_trunc=0.016
    )
    assert stats["num_skipped"] == 1
    assert stats["num_frames"] == 3


def test_empty_scan_raises(tmp_path: Path) -> None:
    scan_dir = tmp_path / "empty"
    scan_dir.mkdir()
    (scan_dir / "meta.json").write_text(
        json.dumps(
            {
                "schema_version": 1,
                "run_id": "empty",
                "device_model": "synthetic",
                "frames": [],
            }
        )
    )
    with pytest.raises(ValueError, match="no frames"):
        reconstruct(scan_dir, tmp_path / "empty.ply")


def test_all_invalid_depth_raises(tmp_path: Path) -> None:
    pose = _look_at(np.array([0.0, 0.0, 0.15]), np.array([0.0, 0.0, PLANE_Z]))
    depth = np.zeros((HEIGHT, WIDTH), dtype=np.float32)
    depth[0, 0] = np.nan
    scan_dir = tmp_path / "invalid"
    scan_dir.mkdir()
    _write_scan(scan_dir, [(pose, depth)])
    with pytest.raises(ValueError, match="no frames with valid depth"):
        reconstruct(scan_dir, tmp_path / "invalid.obj")
