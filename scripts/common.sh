#!/usr/bin/env bash

facescan_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

facescan_load_env() {
  # Load .local/local.env, but never clobber values already present in the
  # environment (explicit env vars and CLI-derived overrides win over the file).
  local file="$1/.local/local.env"
  [ -f "$file" ] || return 0
  local line key val
  while IFS= read -r line; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in
      ''|*[!A-Za-z0-9_]*) continue ;;
    esac
    # Only assign when the variable is currently unset or empty.
    if [ -z "$(eval "printf '%s' \"\${$key:-}\"")" ]; then
      eval "export $key=$val"
    fi
  done <"$file"
}

facescan_is_placeholder_bundle() {
  case "${1:-}" in
    ''|com.example.facescan|YOURTEAMID) return 0 ;;
  esac
  return 1
}

facescan_validate_run_id() {
  local id="$1"
  [ -n "$id" ] || return 1
  [ "${#id}" -le 128 ] || return 1
  case "$id" in
    *[!A-Za-z0-9_-]*) return 1 ;;
  esac
  return 0
}

facescan_project_name() {
  local file="$1" value=""
  value="$(awk '/^name:/ { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }' "$file")"
  value="${value%\"}"
  value="${value#\"}"
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

facescan_target_name() {
  local file="$1" value=""
  value="$(awk '
    /^targets:/ { intarget = 1; next }
    intarget && /^[[:space:]]+[A-Za-z0-9_]+:/ {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/:.*/, "", line)
      print line
      exit
    }
  ' "$file")"
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

facescan_product_name() {
  local file="$1" fallback="$2" value=""
  value="$(awk '/^[[:space:]]+PRODUCT_NAME:/ { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }' "$file")"
  value="${value%\"}"
  value="${value#\"}"
  [ -n "$value" ] || value="$fallback"
  printf '%s' "$value"
}

facescan_bundle_from_project() {
  local file="$1" value=""
  value="$(awk '/^[[:space:]]+PRODUCT_BUNDLE_IDENTIFIER:/ { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }' "$file")"
  value="${value%\"}"
  value="${value#\"}"
  case "$value" in
    ''|YOURTEAMID|com.example.facescan) return 1 ;;
  esac
  printf '%s' "$value"
}

facescan_resolve_team() {
  local profile_name="${FACESCAN_PROFILE_NAME:-iOS Team Provisioning Profile: *}"
  local dir f plist name expires team
  for dir in \
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
    "$HOME/Library/MobileDevice/Provisioning Profiles"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*; do
      [ -f "$f" ] || continue
      plist="$(security cms -D -i "$f" 2>/dev/null)" || continue
      name="$(/usr/libexec/PlistBuddy -c 'Print :Name' /dev/stdin <<<"$plist" 2>/dev/null || true)"
      [ "$name" = "$profile_name" ] || continue
      expires="$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' /dev/stdin <<<"$plist" 2>/dev/null || true)"
      if [ -n "$expires" ]; then
        local expiry_epoch now_epoch
        expiry_epoch="$(date -j -f '%a %b %d %T %Z %Y' "$expires" +%s 2>/dev/null || echo 9999999999)"
        now_epoch="$(date +%s)"
        [ "$expiry_epoch" -lt "$now_epoch" ] && continue
      fi
      team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' /dev/stdin <<<"$plist" 2>/dev/null || true)"
      [ -n "$team" ] || continue
      printf '%s' "$team"
      return 0
    done
  done
  echo "facescan: no unexpired provisioning profile named '$profile_name' found" >&2
  return 1
}

facescan_resolve_udid() {
  local name="$1" json status=0
  json="$(mktemp "${TMPDIR:-/tmp}/facescan-devicectl.XXXXXX")"
  if ! xcrun devicectl list devices --json-output "$json" >/dev/null; then
    rm -f "$json"
    echo "facescan: 'xcrun devicectl list devices' failed" >&2
    return 1
  fi
  python3 - "$json" "$name" <<'PY' || status=$?
import json
import sys

path, name = sys.argv[1], sys.argv[2]
try:
    with open(path) as handle:
        data = json.load(handle)
except Exception as exc:  # noqa: BLE001
    print(f"facescan: cannot read devicectl JSON: {exc}", file=sys.stderr)
    sys.exit(1)

devices = (data.get("result") or {}).get("devices") or []


def text(value):
    return value if isinstance(value, str) else ""


matches = []
for dev in devices:
    props = dev.get("properties") or {}
    hardware = props.get("hardware") or {}
    connection = props.get("connection") or {}
    device_name = text((dev.get("deviceProperties") or {}).get("name")) or text(
        (props.get("state") or {}).get("name")
    )
    if device_name != name:
        continue
    udid = (
        text((dev.get("hardwareProperties") or {}).get("udid"))
        or text(hardware.get("udid"))
        or text(dev.get("identifier"))
    )
    if not udid:
        continue
    rank = (
        1 if text(connection.get("state")) == "available" else 0,
        1 if text(hardware.get("reality")) == "physical" else 0,
        1 if text(connection.get("pairingState")) == "paired" else 0,
    )
    matches.append((rank, udid))

if not matches:
    sys.exit(2)

matches.sort(key=lambda item: item[0], reverse=True)
best_rank, best_udid = matches[0]
if len(matches) > 1 and matches[1][0] == best_rank and matches[1][1] != best_udid:
    sys.exit(3)

sys.stdout.write(best_udid)
PY
  rm -f "$json"
  case "$status" in
    0) return 0 ;;
    2) echo "facescan: device not found in devicectl list: $name" >&2; return 1 ;;
    3) echo "facescan: multiple devices named '$name'; pass a UDID-derived device instead" >&2; return 1 ;;
    *) echo "facescan: failed to parse devicectl device list" >&2; return 1 ;;
  esac
}

facescan_effective_bundle() {
  local explicit="$1" value
  if [ -n "$explicit" ]; then
    printf '%s' "$explicit"
    return 0
  fi
  value="${FACESCAN_BUNDLE_ID:-}"
  if [ -n "$value" ] && ! facescan_is_placeholder_bundle "$value"; then
    printf '%s' "$value"
    return 0
  fi
  return 1
}

facescan_effective_udid() {
  local explicit="$1"
  if [ -n "$explicit" ]; then
    facescan_resolve_udid "$explicit"
    return
  fi
  if [ -n "${FACESCAN_DEVICE_UDID:-}" ]; then
    printf '%s' "$FACESCAN_DEVICE_UDID"
    return 0
  fi
  if [ -n "${FACESCAN_DEVICE:-}" ]; then
    facescan_resolve_udid "$FACESCAN_DEVICE"
    return
  fi
  return 1
}

facescan_write_env() {
  local root="$1" device="$2" bundle="$3" team="$4" udid="$5"
  local dir tmp
  device="${device:-${FACESCAN_DEVICE:-}}"
  bundle="${bundle:-${FACESCAN_BUNDLE_ID:-}}"
  team="${team:-${FACESCAN_DEVELOPMENT_TEAM:-}}"
  udid="${udid:-${FACESCAN_DEVICE_UDID:-}}"
  dir="$root/.local"
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/local.env.XXXXXX")"
  {
    printf 'FACESCAN_DEVICE=%q\n' "$device"
    printf 'FACESCAN_BUNDLE_ID=%q\n' "$bundle"
    printf 'FACESCAN_DEVELOPMENT_TEAM=%q\n' "$team"
    printf 'FACESCAN_DEVICE_UDID=%q\n' "$udid"
  } >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$dir/local.env"
}
