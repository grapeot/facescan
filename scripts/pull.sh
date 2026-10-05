#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
. "$here/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/pull.sh --run-id ID --out DIR [--device NAME] [--bundle-id ID]

Copy Documents/scan_<run_id>/ from the app container to a local directory.

Options:
  --run-id ID       Run identifier (required).
  --out DIR         Local destination directory (required). May not already
                    exist as a non-empty directory.
  --device NAME     Device name, overrides FACESCAN_DEVICE.
  --bundle-id ID    Bundle id, overrides FACESCAN_BUNDLE_ID.
  -h, --help        Show this help.

The directory lands as DIR itself, containing meta.json, depth_*.bin, and
color_*.jpg. Device and bundle id default to .local/local.env.
EOF
}

run_id=""
out=""
device=""
bundle=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-id)
      [ "$#" -ge 2 ] || { echo "pull: --run-id needs a value" >&2; exit 2; }
      run_id="$2"; shift ;;
    --run-id=*) run_id="${1#--run-id=}" ;;
    --out)
      [ "$#" -ge 2 ] || { echo "pull: --out needs a value" >&2; exit 2; }
      out="$2"; shift ;;
    --out=*) out="${1#--out=}" ;;
    --device)
      [ "$#" -ge 2 ] || { echo "pull: --device needs a value" >&2; exit 2; }
      device="$2"; shift ;;
    --device=*) device="${1#--device=}" ;;
    --bundle-id)
      [ "$#" -ge 2 ] || { echo "pull: --bundle-id needs a value" >&2; exit 2; }
      bundle="$2"; shift ;;
    --bundle-id=*) bundle="${1#--bundle-id=}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "pull: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[ -n "$run_id" ] || { echo "pull: --run-id is required" >&2; usage >&2; exit 2; }
[ -n "$out" ] || { echo "pull: --out is required" >&2; usage >&2; exit 2; }
if ! facescan_validate_run_id "$run_id"; then
  echo "pull: invalid run id '$run_id' (allowed: [A-Za-z0-9_-]+, max 128 chars)" >&2
  exit 2
fi

if [ -e "$out" ]; then
  if [ ! -d "$out" ]; then
    echo "pull: --out exists and is not a directory: $out" >&2
    exit 1
  fi
  if [ -n "$(ls -A "$out" 2>/dev/null)" ]; then
    echo "pull: --out is a non-empty directory, refusing to overwrite: $out" >&2
    exit 1
  fi
fi

root="$(facescan_root)"
facescan_load_env "$root"

udid="$(facescan_effective_udid "$device")" || {
  echo "pull: no device; pass --device NAME or set FACESCAN_DEVICE" >&2
  exit 2
}
bundle_id="$(facescan_effective_bundle "$bundle")" || {
  echo "pull: no real bundle id; pass --bundle-id or run build_ios.sh first" >&2
  exit 2
}

mkdir -p "$(dirname "$out")"
xcrun devicectl device copy from \
  --device "$udid" \
  --domain-type appDataContainer \
  --domain-identifier "$bundle_id" \
  --source "Documents/scan_$run_id" \
  --destination "$out"

echo "pull: copied scan '$run_id' to $out"
