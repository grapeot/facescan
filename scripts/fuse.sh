#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/fuse.sh <scan_dir> --out FILE [--voxel V] [--trunc T] \
                       [--depth-min A] [--depth-max B]

Run the Mac-side TSDF reconstruction: python -m facescan reconstruct.

Arguments:
  scan_dir          Directory pulled by pull.sh (contains meta.json).
  --out FILE        Output mesh path, e.g. out.ply (required).
  --voxel V         TSDF voxel size in metres (default: facescan CLI default).
  --trunc T         TSDF truncation distance in metres.
  --depth-min A     Minimum valid depth in metres.
  --depth-max B     Maximum valid depth in metres.
  --frame F         Fusion reference frame: auto (default), world, or face.
  --max-frames N    Uniformly subsample to at most N frames before fusing.
  --max-reproj-error M
                    Drop frames whose neighbour reprojection error exceeds M metres.
  -h, --help        Show this help.

Runs through `uv run` so the project environment created by setup.sh is used.
Unspecified tuning flags are left to the Python CLI defaults.
EOF
}

scan_dir=""
out=""
extra=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out)
      [ "$#" -ge 2 ] || { echo "fuse: --out needs a value" >&2; exit 2; }
      out="$2"; shift ;;
    --out=*) out="${1#--out=}" ;;
    --voxel|--trunc|--depth-min|--depth-max|--frame|--max-frames|--max-reproj-error)
      [ "$#" -ge 2 ] || { echo "fuse: $1 needs a value" >&2; exit 2; }
      extra+=("$1" "$2"); shift ;;
    --voxel=*|--trunc=*|--depth-min=*|--depth-max=*|--frame=*|--max-frames=*|--max-reproj-error=*) extra+=("$1") ;;
    -h|--help) usage; exit 0 ;;
    -*)
      echo "fuse: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [ -n "$scan_dir" ]; then
        echo "fuse: unexpected extra argument: $1" >&2; usage >&2; exit 2
      fi
      scan_dir="$1" ;;
  esac
  shift
done

[ -n "$scan_dir" ] || { echo "fuse: <scan_dir> is required" >&2; usage >&2; exit 2; }
[ -n "$out" ] || { echo "fuse: --out is required" >&2; usage >&2; exit 2; }
[ -d "$scan_dir" ] || { echo "fuse: scan directory not found: $scan_dir" >&2; exit 1; }

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

uv run python -m facescan reconstruct "$scan_dir" --out "$out" ${extra[@]+"${extra[@]}"}
echo "fuse: wrote $out"
