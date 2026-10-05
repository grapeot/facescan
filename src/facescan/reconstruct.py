"""TSDF fusion of a TrueDepth scan directory into a triangle mesh."""

from __future__ import annotations

from pathlib import Path

import numpy as np
import open3d as o3d

from facescan.contract import arkit_pose_to_extrinsic, load_depth, load_scan


def reconstruct(
    scan_dir: Path,
    out_path: Path,
    *,
    voxel_size: float = 0.0015,
    sdf_trunc: float = 0.03,
    depth_min: float = 0.15,
    depth_max: float = 0.60,
    with_color: bool = False,
    frame: str = "auto",
    max_frames: int | None = None,
    max_reproj_error: float | None = None,
) -> dict:
    """Fuse a scan into a mesh. Returns num_frames, num_vertices, num_triangles, out_path.

    `max_frames` uniformly subsamples the (already outlier-filtered) frames down
    to at most that many before integrating. A dense scan with tight keyframe
    thresholds can produce far more frames than the volume needs; near-duplicate
    frames add nothing and slow integration, so an even spread across the motion
    is better than all of them.

    `max_reproj_error` (metres) keeps only frames whose depth agrees with their
    neighbours, measured independently of the pose heuristic: reproject a
    frame's points into the previous frame via their relative pose and compare
    predicted vs observed depth. A frame that disagrees with both neighbours
    carries a bad pose or bad depth and is dropped before fusing.

    `frame` selects the reference frame for fusing, which matters a lot:
    - "world": fuse in ARKit world coordinates. Correct when the camera orbits a
      stationary subject.
    - "face": fuse in the ARFaceAnchor frame. Correct when the subject rotates
      their head while the camera stays still — world-frame fusion would scatter
      the points, but the face frame un-rotates each frame back into alignment.
    - "auto" (default): use "face" when every frame carries a face_pose, else
      "world".
    """
    scan_dir = Path(scan_dir)
    out_path = Path(out_path)
    _require_mesh_suffix(out_path)

    scan = load_scan(scan_dir)
    if not scan.frames:
        raise ValueError(f"scan {scan_dir} has no frames; refusing to write an empty mesh")
    if frame == "auto":
        frame = "face" if all(f.face_pose is not None for f in scan.frames) else "world"
    if frame not in ("world", "face"):
        raise ValueError(f"unknown frame {frame!r}; expected world, face, or auto")
    if frame == "face" and not all(f.face_pose is not None for f in scan.frames):
        frame = "world"

    color_type = (
        o3d.pipelines.integration.TSDFVolumeColorType.RGB8
        if with_color
        else o3d.pipelines.integration.TSDFVolumeColorType.NoColor
    )
    volume = o3d.pipelines.integration.ScalableTSDFVolume(
        voxel_length=float(voxel_size),
        sdf_trunc=float(sdf_trunc),
        color_type=color_type,
        depth_sampling_stride=1,
    )

    used = 0
    skipped_outlier = 0
    # Pre-read depth once; reuse for both outlier filtering and integration.
    depths: dict[int, np.ndarray] = {}
    for keyframe in scan.frames:
        depths[keyframe.index] = _mask_depth(
            load_depth(scan_dir, keyframe), depth_min, depth_max
        )

    keep = _reject_inconsistent_frames(scan.frames, depths, depth_min, depth_max)
    candidates = [f for f in scan.frames if f.index in keep]
    skipped_outlier = len(scan.frames) - len(candidates)

    # Independent quality signal: drop frames whose depth disagrees with their
    # neighbours under the poses we are about to fuse with. This catches frames
    # the position heuristic above cannot see (good position, bad local
    # alignment) and is the same signal scripts/crosscheck_outliers.py reports.
    if max_reproj_error is not None:
        quality = _reprojection_consistency(candidates, depths, frame, depth_min, depth_max)
        candidates = [
            f for f in candidates
            if quality.get(f.index, float("inf")) <= max_reproj_error
        ]
        skipped_outlier = len(scan.frames) - len(candidates)

    selected = _uniform_subsample(candidates, max_frames)
    selected_indices = {f.index for f in selected}
    for keyframe in scan.frames:
        if keyframe.index not in selected_indices:
            continue
        depth = depths[keyframe.index]
        color = _color_array(scan_dir, keyframe, with_color)
        rgbd = _rgbd(color, depth, depth_max)
        intrinsic = _intrinsic(keyframe)
        extrinsic = np.ascontiguousarray(
            arkit_pose_to_extrinsic(_select_pose(keyframe, frame)), dtype=np.float64
        )
        volume.integrate(rgbd, intrinsic, extrinsic)
        used += 1

    if used == 0:
        raise ValueError(
            f"scan {scan_dir} has no frames with valid depth in "
            f"[{depth_min}, {depth_max}] m; refusing to write an empty mesh"
        )

    mesh = volume.extract_triangle_mesh()
    mesh.compute_vertex_normals()
    if len(mesh.vertices) == 0 or len(mesh.triangles) == 0:
        raise RuntimeError(
            f"TSDF fusion of {scan_dir} produced an empty mesh "
            f"({len(mesh.vertices)} vertices, {len(mesh.triangles)} triangles)"
        )

    out_path.parent.mkdir(parents=True, exist_ok=True)
    if not o3d.io.write_triangle_mesh(str(out_path), mesh):
        raise RuntimeError(f"failed to write mesh to {out_path}")

    return {
        "frame": frame,
        "num_frames": int(used),
        "num_candidates": int(len(candidates)),
        "num_skipped": int(skipped_outlier),
        "num_vertices": int(len(mesh.vertices)),
        "num_triangles": int(len(mesh.triangles)),
        "out_path": str(out_path),
    }


def _relative_reprojection_error(a, b, da, db, depth_min: float, depth_max: float, step: int = 16) -> float:
    """Median |predicted - observed| depth reprojecting frame a into frame b.

    Runs in the same reference frame used for fusion (the caller passes frames
    whose pose accessor already accounts for the frame choice), so the signal is
    consistent with what integration will actually do. NaN when there is no
    overlap to judge.
    """
    ka, kb = a.intrinsics, b.intrinsics
    flip = np.array([1.0, -1.0, -1.0, 1.0])
    # Both select_pose() results are camera->reference in the same (GL) convention,
    # so this maps a's CV points into b's CV frame for either reference choice.
    rel = np.linalg.inv(_select_pose(b, a._reference)) @ _select_pose(a, a._reference)
    h, w = da.shape
    errs = []
    for v in range(20, h - 20, step):
        for u in range(20, w - 20, step):
            z = da[v, u]
            if not (depth_min < z < depth_max) or not np.isfinite(z):
                continue
            x = (u - ka[0, 2]) * z / ka[0, 0]
            y = (v - ka[1, 2]) * z / ka[1, 1]
            cam_b = (rel @ (np.array([x, y, z, 1.0]) * flip)) * flip
            if cam_b[2] <= 0:
                errs.append(depth_max)
                continue
            uu = kb[0, 0] * cam_b[0] / cam_b[2] + kb[0, 2]
            vv = kb[1, 1] * cam_b[1] / cam_b[2] + kb[1, 2]
            ui, vi = int(round(uu)), int(round(vv))
            if 0 <= ui < w and 0 <= vi < h:
                zo = db[vi, ui]
                if depth_min < zo < depth_max:
                    errs.append(abs(zo - cam_b[2]))
    return float(np.median(errs)) if errs else float("nan")


def _reprojection_consistency(frames, depths, reference: str, depth_min: float, depth_max: float) -> dict[int, float]:
    """Per-frame min reprojection error against its neighbours (lower is better)."""
    for f in frames:
        f._reference = reference
    result: dict[int, float] = {}
    for i, f in enumerate(frames):
        errs = []
        if i > 0:
            errs.append(
                _relative_reprojection_error(
                    frames[i - 1], f, depths[frames[i - 1].index], depths[f.index],
                    depth_min, depth_max,
                )
            )
        if i < len(frames) - 1:
            errs.append(
                _relative_reprojection_error(
                    f, frames[i + 1], depths[f.index], depths[frames[i + 1].index],
                    depth_min, depth_max,
                )
            )
        valid = [e for e in errs if np.isfinite(e)]
        result[f.index] = min(valid) if valid else float("inf")
    return result


def _uniform_subsample(frames, max_frames: int | None):
    """Evenly pick at most max_frames frames across the list, keeping first and last."""
    if max_frames is None or max_frames <= 0 or len(frames) <= max_frames:
        return list(frames)
    count = len(frames)
    indices = np.linspace(0, count - 1, max_frames)
    picked = sorted({int(round(i)) for i in indices})
    return [frames[i] for i in picked]


def _select_pose(frame, reference: str) -> np.ndarray:
    """Camera-to-<reference> pose used to place a keyframe in the fusion volume."""
    if reference == "face":
        return np.linalg.inv(frame.face_pose) @ frame.pose  # camera -> face frame
    return frame.pose  # camera -> world


def _reject_inconsistent_frames(
    frames, depths: dict[int, np.ndarray], depth_min: float, depth_max: float
) -> set[int]:
    """Drop frames whose face centre, seen through their own pose, is far from the median.

    ARKit face tracking occasionally emits a frame with a spurious pose (a
    re-localisation spike), or a frame where the subject is momentarily lost and
    only background is visible. Both make the frame's world face position leap
    away from the rest. A rigid scan of a roughly stationary subject keeps that
    position tightly clustered, so a median-based position gate removes the bad
    frames without needing to trust any single frame.
    """
    centers: dict[int, np.ndarray] = {}
    for frame in frames:
        depth = depths[frame.index]
        if float(np.count_nonzero(depth)) < 0.15 * depth.size:
            continue  # too little face visible; cannot judge position
        h, w = depth.shape
        cy, cx = h // 2, w // 2
        valid = depth[(depth > depth_min) & (depth < depth_max)]
        z = float(depth[cy, cx]) if depth[cy, cx] > 0 else float(np.median(valid))
        k = frame.intrinsics
        cam_gl = np.array(
            [
                (cx - k[0, 2]) * z / k[0, 0],
                -((cy - k[1, 2]) * z / k[1, 1]),
                -z,
                1.0,
            ]
        )
        centers[frame.index] = (frame.pose @ cam_gl)[:3]

    if not centers:
        return set()

    stack = np.array(list(centers.values()))
    median = np.median(stack, axis=0)
    # Allow ~15cm of real subject drift plus margin; beyond that it is a spike.
    return {
        index
        for index, center in centers.items()
        if float(np.linalg.norm(center - median)) <= 0.15
    }


def _require_mesh_suffix(out_path: Path) -> None:
    if out_path.suffix.lower() not in {".ply", ".obj"}:
        raise ValueError(
            f"unsupported output suffix {out_path.suffix!r}; expected .ply or .obj"
        )


def _mask_depth(depth: np.ndarray, depth_min: float, depth_max: float) -> np.ndarray:
    masked = np.array(depth, dtype=np.float32, copy=True)
    invalid = (
        ~np.isfinite(masked)
        | (masked <= 0)
        | (masked < depth_min)
        | (masked > depth_max)
    )
    masked[invalid] = 0
    return masked


def _intrinsic(frame) -> o3d.camera.PinholeCameraIntrinsic:
    k = frame.intrinsics
    return o3d.camera.PinholeCameraIntrinsic(
        int(frame.depth_width),
        int(frame.depth_height),
        float(k[0, 0]),
        float(k[1, 1]),
        float(k[0, 2]),
        float(k[1, 2]),
    )


def _rgbd(color: np.ndarray, depth: np.ndarray, depth_max: float) -> o3d.geometry.RGBDImage:
    color_img = o3d.geometry.Image(np.ascontiguousarray(color, dtype=np.uint8))
    depth_img = o3d.geometry.Image(np.ascontiguousarray(depth, dtype=np.float32))
    return o3d.geometry.RGBDImage.create_from_color_and_depth(
        color_img,
        depth_img,
        depth_scale=1.0,
        depth_trunc=float(depth_max) + 1e-6,
        convert_rgb_to_intensity=False,
    )


def _color_array(scan_dir: Path, frame, with_color: bool) -> np.ndarray:
    h, w = int(frame.depth_height), int(frame.depth_width)
    if not with_color:
        return np.full((h, w, 3), 255, dtype=np.uint8)
    path = scan_dir / frame.color_file if frame.color_file else None
    if path is None or not path.is_file():
        return np.full((h, w, 3), 255, dtype=np.uint8)
    raw = np.asarray(o3d.io.read_image(str(path)))
    if raw.size == 0:
        return np.full((h, w, 3), 255, dtype=np.uint8)
    if raw.ndim == 2:
        raw = np.stack([raw, raw, raw], axis=-1)
    raw = raw[:, :, :3]
    return _resize_nn(raw, h, w)


def _resize_nn(image: np.ndarray, height: int, width: int) -> np.ndarray:
    if image.shape[0] == height and image.shape[1] == width:
        return np.ascontiguousarray(image, dtype=np.uint8)
    ys = np.linspace(0, image.shape[0] - 1, height).astype(np.int32)
    xs = np.linspace(0, image.shape[1] - 1, width).astype(np.int32)
    return np.ascontiguousarray(image[ys][:, xs], dtype=np.uint8)
