#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
xcodebuild -project "$REPO_DIR/DesignCanvas/DesignCanvas.xcodeproj" \
  -scheme DesignCanvas -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$REPO_DIR/.build/native" \
  -clonedSourcePackagesDirPath "$REPO_DIR/.build/packages" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= test
