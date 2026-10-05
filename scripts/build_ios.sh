#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
. "$here/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/build_ios.sh [--install] [--device NAME]

Generate the Xcode project with xcodegen and build FaceScan for iOS.

Options:
  --install        Also install the built app on the paired device.
  --device NAME    Device name as shown by `xcrun devicectl list devices`.
                   Required with --install. Defaults to FACESCAN_DEVICE.
  -h, --help       Show this help.

Environment:
  FACESCAN_DEVICE         Default device name (private; keep in .local/local.env).
  FACESCAN_BUNDLE_ID      Override the bundle id resolved from ios/project.yml.
  FACESCAN_CONFIGURATION  Build configuration (default: Debug).
  FACESCAN_SCHEME         Override the scheme resolved from ios/project.yml.

The development team id is read at build time from a cached provisioning
profile and written to .local/local.env. It is never hardcoded here or echoed.
EOF
}

install=0
device=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --install) install=1 ;;
    --device)
      [ "$#" -ge 2 ] || { echo "build_ios: --device needs a value" >&2; usage >&2; exit 2; }
      device="$2"
      shift
      ;;
    --device=*)
      device="${1#--device=}"
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "build_ios: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

root="$(facescan_root)"
facescan_load_env "$root"

device="${device:-${FACESCAN_DEVICE:-}}"
configuration="${FACESCAN_CONFIGURATION:-Debug}"

if [ "$install" -eq 1 ] && [ -z "$device" ]; then
  echo "build_ios: --install requires --device NAME or FACESCAN_DEVICE" >&2
  usage >&2
  exit 2
fi

if [ -n "$device" ]; then
  case "$device" in
    *,*) echo "build_ios: device name must not contain commas" >&2; exit 2 ;;
  esac
fi

project_yml="$root/ios/project.yml"
[ -f "$project_yml" ] || { echo "build_ios: missing $project_yml" >&2; exit 1; }

project="$(facescan_project_name "$project_yml")" || {
  echo "build_ios: cannot parse 'name' from ios/project.yml" >&2; exit 1
}
scheme="${FACESCAN_SCHEME:-$(facescan_target_name "$project_yml")}" || {
  echo "build_ios: cannot parse a target name from ios/project.yml" >&2; exit 1
}
product="$(facescan_product_name "$project_yml" "$project")"

bundle="${FACESCAN_BUNDLE_ID:-}"
if [ -z "$bundle" ] || facescan_is_placeholder_bundle "$bundle"; then
  bundle="$(facescan_bundle_from_project "$project_yml" || true)"
fi
if [ -z "$bundle" ] || facescan_is_placeholder_bundle "$bundle"; then
  bundle="com.example.facescan"
  echo "build_ios: WARNING no real bundle id in FACESCAN_BUNDLE_ID or ios/project.yml; using placeholder" >&2
fi

command -v xcodegen >/dev/null 2>&1 || {
  echo "build_ios: xcodegen not found on PATH" >&2; exit 1
}

team="$(facescan_resolve_team)" || exit 1

udid=""
if [ -n "$device" ]; then
  if udid="$(facescan_resolve_udid "$device")"; then
    :
  else
    echo "build_ios: could not resolve '$device' to a devicectl identifier" >&2
    exit 1
  fi
fi

facescan_write_env "$root" "$device" "$bundle" "$team" "$udid"
echo "build_ios: wrote $root/.local/local.env"

(
  cd "$root/ios"
  xcodegen generate
)

derived="$root/ios/build"
destination="generic/platform=iOS"
if [ "$install" -eq 1 ]; then
  destination="platform=iOS,name=$device"
fi

xcodebuild \
  -project "$root/ios/$project.xcodeproj" \
  -scheme "$scheme" \
  -configuration "$configuration" \
  -destination "$destination" \
  -derivedDataPath "$derived" \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="$team" \
  PRODUCT_BUNDLE_IDENTIFIER="$bundle" \
  build

app="$derived/Build/Products/$configuration-iphoneos/$product.app"
if [ ! -d "$app" ]; then
  echo "build_ios: expected app bundle not found: $app" >&2
  exit 1
fi
echo "build_ios: built $app"

if [ "$install" -eq 1 ]; then
  xcrun devicectl device install app --device "$udid" "$app"
  echo "build_ios: installed on '$device'"
fi
