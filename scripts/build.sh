#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/xcode-env.sh"
cd "$TABLEWISE_ROOT"
command -v xcodegen >/dev/null || { echo "XcodeGen is required (brew install xcodegen)." >&2; exit 1; }
xcodegen generate --spec ios/project.yml
mkdir -p .build
if ! xcodebuild -project ios/Tablewise.xcodeproj -scheme Tablewise \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$TABLEWISE_DERIVED" CODE_SIGNING_ALLOWED=NO build \
  > .build/build.log 2>&1; then
  tail -n 80 .build/build.log
  exit 1
fi
echo "Build succeeded: .build/DerivedData/Build/Products/Debug-iphonesimulator/Tablewise.app"
echo "Full log: .build/build.log"
