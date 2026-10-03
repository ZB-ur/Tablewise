#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/xcode-env.sh"
cd "$TABLEWISE_ROOT"
# Explicit project-only targets keep small-screen checks on the same launch path.
usage() { echo 'Usage: scripts/run-simulator.sh [dev|compact] [--relaunch]' >&2; }
case "${1:-dev}" in
  dev) TABLEWISE_DEVICE_NAME='Tablewise Dev'; TABLEWISE_DEVICE_TYPE='com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro'; TABLEWISE_DEVICE_KEY='dev' ;;
  compact) TABLEWISE_DEVICE_NAME='Tablewise Compact'; TABLEWISE_DEVICE_TYPE='com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation'; TABLEWISE_DEVICE_KEY='compact' ;;
  *) usage; exit 2 ;;
esac
TABLEWISE_RELAUNCH=false
if [[ $# -eq 2 && "$2" == --relaunch ]]; then
  TABLEWISE_RELAUNCH=true
elif [[ $# -gt 1 ]]; then
  usage; exit 2
fi
TABLEWISE_APP="$TABLEWISE_DERIVED/Build/Products/Debug-iphonesimulator/Tablewise.app"
if [[ "$TABLEWISE_RELAUNCH" == false ]]; then
  [[ -d "$TABLEWISE_APP" ]] || { echo "Run scripts/build.sh first." >&2; exit 1; }
fi
mkdir -p .local
# Reuse only this project's named simulator; never erase or shut down others.
TABLEWISE_DEVICE=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
matches=[d for devices in json.load(sys.stdin)["devices"].values() for d in devices if d["name"]==sys.argv[1]]
if len(matches)>1: sys.exit("Multiple matching project devices; resolve explicitly before running.")
if matches and matches[0]["deviceTypeIdentifier"] != sys.argv[2]: sys.exit("Project device type mismatch; resolve explicitly before running.")
print(matches[0]["udid"] if matches else "")' "$TABLEWISE_DEVICE_NAME" "$TABLEWISE_DEVICE_TYPE")
if [[ -z "$TABLEWISE_DEVICE" ]]; then
  if [[ "$TABLEWISE_RELAUNCH" == true ]]; then
    echo "No existing $TABLEWISE_DEVICE_NAME simulator; relaunch requires an installed version." >&2
    exit 1
  fi
  TABLEWISE_RUNTIME=$(xcrun simctl list runtimes -j | python3 -c '
import json,sys
items=[r for r in json.load(sys.stdin)["runtimes"] if r["isAvailable"] and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")]
if not items: sys.exit("No available iOS simulator runtime.")
print(max(items,key=lambda r:tuple(map(int,r["version"].split("."))))["identifier"])')
  TABLEWISE_DEVICE=$(xcrun simctl create "$TABLEWISE_DEVICE_NAME" "$TABLEWISE_DEVICE_TYPE" "$TABLEWISE_RUNTIME")
fi
printf '%s\n' "$TABLEWISE_DEVICE" > ".local/simulator-$TABLEWISE_DEVICE_KEY-udid"
# Preserve the existing default-device pointer used by older handoff records.
if [[ "$TABLEWISE_DEVICE_KEY" == dev ]]; then printf '%s\n' "$TABLEWISE_DEVICE" > .local/simulator-udid; fi
TABLEWISE_STATE=$(xcrun simctl list devices -j | python3 -c 'import json,sys; print(next(d["state"] for ds in json.load(sys.stdin)["devices"].values() for d in ds if d["udid"]==sys.argv[1]))' "$TABLEWISE_DEVICE")
if [[ "$TABLEWISE_STATE" != Booted ]]; then xcrun simctl boot "$TABLEWISE_DEVICE"; fi
xcrun simctl bootstatus "$TABLEWISE_DEVICE" -b
if [[ "$TABLEWISE_RELAUNCH" == true ]]; then
  xcrun simctl get_app_container "$TABLEWISE_DEVICE" dev.tablewise.app app >/dev/null || {
    echo "Tablewise is not installed on $TABLEWISE_DEVICE_NAME; relaunch does not install it." >&2
    exit 1
  }
fi
open -a Simulator --args -CurrentDeviceUDID "$TABLEWISE_DEVICE"
if [[ "$TABLEWISE_RELAUNCH" == false ]]; then
  xcrun simctl install "$TABLEWISE_DEVICE" "$TABLEWISE_APP"
fi
xcrun simctl launch --terminate-running-process "$TABLEWISE_DEVICE" dev.tablewise.app
echo "Tablewise simulator: $TABLEWISE_DEVICE_NAME ($TABLEWISE_DEVICE)"
