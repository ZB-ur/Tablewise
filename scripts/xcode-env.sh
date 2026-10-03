#!/bin/bash
# Source from project scripts; leave the global xcode-select setting untouched.
set -euo pipefail
TABLEWISE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
  echo "Set DEVELOPER_DIR to an installed Xcode.app/Contents/Developer." >&2
  exit 1
fi
TABLEWISE_DERIVED="$TABLEWISE_ROOT/.build/DerivedData"
