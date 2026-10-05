#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
. "$here/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/scan.sh <start|stop|status> [options]

Control the FaceScan capture app on a paired iPhone over devicectl.

Subcommands:
  start --run-id ID   Deep-link launch a new recording. Uses
                      facescan://record?run_id=ID via a cold launch
                      (--terminate-existing).
  stop                Deep-link stop the current recording via
                      xcrun devicectl device process openURL.
  status              Copy and print Documents/status.json, and report whether
                      Documents/scan_<run_id>/meta.json exists.

Options:
  --run-id ID         Run identifier (start: required; status: optional, to
                      check a specific scan directory).
  --device NAME       Device name, overrides FACESCAN_DEVICE.
  --bundle-id ID      Bundle id, overrides FACESCAN_BUNDLE_ID.
  -h, --help          Show this help.

A valid run id matches [A-Za-z0-9_-]+ and is at most 128 chars. Device and
bundle id default to .local/local.env (written by build_ios.sh).

Exit codes: 0 success; 2 usage error; 1 runtime error (device unreachable,
app missing, copy failed).
EOF
}

command="${1:-}"
case "$command" in
  -h|--help) usage; exit 0 ;;
  start|stop|status) ;;
  '') usage >&2; exit 2 ;;
  *) echo "scan: unknown subcommand: $command" >&2; usage >&2; exit 2 ;;
esac
shift

run_id=""
device=""
bundle=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-id)
      [ "$#" -ge 2 ] || { echo "scan: --run-id needs a value" >&2; exit 2; }
      run_id="$2"; shift ;;
    --run-id=*) run_id="${1#--run-id=}" ;;
    --device)
      [ "$#" -ge 2 ] || { echo "scan: --device needs a value" >&2; exit 2; }
      device="$2"; shift ;;
    --device=*) device="${1#--device=}" ;;
    --bundle-id)
      [ "$#" -ge 2 ] || { echo "scan: --bundle-id needs a value" >&2; exit 2; }
      bundle="$2"; shift ;;
    --bundle-id=*) bundle="${1#--bundle-id=}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "scan: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ "$command" = "start" ]; then
  [ -n "$run_id" ] || { echo "scan: start requires --run-id ID" >&2; usage >&2; exit 2; }
fi
if [ -n "$run_id" ] && ! facescan_validate_run_id "$run_id"; then
  echo "scan: invalid run id '$run_id' (allowed: [A-Za-z0-9_-]+, max 128 chars)" >&2
  exit 2
fi

root="$(facescan_root)"
facescan_load_env "$root"

udid="$(facescan_effective_udid "$device")" || {
  echo "scan: no device; pass --device NAME or set FACESCAN_DEVICE" >&2
  exit 2
}
bundle_id="$(facescan_effective_bundle "$bundle")" || {
  echo "scan: no real bundle id; pass --bundle-id or run build_ios.sh first" >&2
  exit 2
}

case "$command" in
  start)
    url="facescan://record?run_id=$run_id"
    xcrun devicectl device process launch \
      --device "$udid" \
      --terminate-existing \
      --payload-url "$url" \
      "$bundle_id"
    echo "scan: requested start for run '$run_id'"
    ;;

  stop)
    xcrun devicectl device process openURL --device "$udid" "facescan://stop"
    echo "scan: requested stop"
    ;;

  status)
    # devicectl copy from needs an existing destination directory.
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/facescan-status.XXXXXX")"
    copy_status=0
    xcrun devicectl device copy from \
      --device "$udid" \
      --domain-type appDataContainer \
      --domain-identifier "$bundle_id" \
      --source "Documents/status.json" \
      --destination "$tmp/status.json" || copy_status=$?

    if [ "$copy_status" -ne 0 ]; then
      rm -f "$tmp/status.json"
      echo "scan: could not read Documents/status.json (app installed and launched?)" >&2
      rmdir "$tmp" 2>/dev/null || true
      exit "$copy_status"
    fi

    echo "--- Documents/status.json ---"
    cat "$tmp/status.json"
    echo
    echo "--- scan directory ---"

    if [ -z "$run_id" ]; then
      run_id="$(python3 -c '
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
value = data.get("run_id")
if isinstance(value, str) and value:
    sys.stdout.write(value)
' "$tmp/status.json" || true)"
    fi

    rm -f "$tmp/status.json"
    rmdir "$tmp" 2>/dev/null || true

    if [ -z "$run_id" ]; then
      echo "meta.json: unknown (no --run-id and status.json has no run_id)"
      exit 0
    fi

    files_json="$(mktemp "${TMPDIR:-/tmp}/facescan-files.XXXXXX")"
    files_err="$(mktemp "${TMPDIR:-/tmp}/facescan-files-err.XXXXXX")"
    files_status=0
    xcrun devicectl device info files \
      --device "$udid" \
      --domain-type appDataContainer \
      --domain-identifier "$bundle_id" \
      --subdirectory "Documents/scan_$run_id" \
      --recurse \
      --json-output "$files_json" 2>"$files_err" || files_status=$?

    if [ "$files_status" -ne 0 ]; then
      if grep -Eiq 'not found|no such file|does not exist|260' "$files_err"; then
        echo "meta.json: absent (Documents/scan_$run_id not present)"
        rm -f "$files_json" "$files_err"
        exit 0
      fi
      cat "$files_err" >&2
      rm -f "$files_json" "$files_err"
      exit "$files_status"
    fi

    if python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
text = json.dumps(data)
sys.exit(0 if "meta.json" in text else 3)
' <"$files_json"; then
      echo "meta.json: present"
    else
      echo "meta.json: absent"
    fi
    rm -f "$files_json" "$files_err"
    ;;
esac
