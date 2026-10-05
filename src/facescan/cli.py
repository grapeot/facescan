"""Command-line entry for the Mac-side fusion pipeline."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from facescan.diagnose import diagnose
from facescan.reconstruct import reconstruct


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="facescan")
    sub = parser.add_subparsers(dest="command")

    rec = sub.add_parser("reconstruct", help="Fuse a scan directory into a triangle mesh")
    rec.add_argument("scan_dir", type=Path)
    rec.add_argument("--out", type=Path, required=True)
    rec.add_argument("--voxel", type=float, default=0.0015)
    rec.add_argument("--trunc", type=float, default=0.03)
    rec.add_argument("--depth-min", type=float, default=0.15)
    rec.add_argument("--depth-max", type=float, default=0.6)
    rec.add_argument("--with-color", action="store_true")
    rec.add_argument(
        "--frame",
        choices=["auto", "world", "face"],
        default="auto",
        help="Fusion reference frame (default: auto).",
    )
    rec.add_argument(
        "--max-frames",
        type=int,
        default=None,
        help="Uniformly subsample to at most this many frames before fusing.",
    )
    rec.add_argument(
        "--max-reproj-error",
        type=float,
        default=None,
        help="Drop frames whose neighbour reprojection error (metres) exceeds this.",
    )

    diag = sub.add_parser("diagnose", help="Report pose-quality evidence for a scan")
    diag.add_argument("scan_dir", type=Path)

    args = parser.parse_args(argv)
    if args.command is None:
        parser.print_help()
        return 0
    if args.command == "diagnose":
        print(json.dumps(diagnose(args.scan_dir), indent=2))
        return 0
    if args.command == "reconstruct":
        stats = reconstruct(
            args.scan_dir,
            args.out,
            voxel_size=args.voxel,
            sdf_trunc=args.trunc,
            depth_min=args.depth_min,
            depth_max=args.depth_max,
            with_color=args.with_color,
            frame=args.frame,
            max_frames=args.max_frames,
            max_reproj_error=args.max_reproj_error,
        )
        print(json.dumps(stats))
        return 0
    parser.print_help()
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
