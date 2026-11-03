#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
derived_data="${CODEX_SWITCHER_DERIVED_DATA:-$project_dir/.build/xcode}"
xcodebuild -project "$project_dir/CodexAccountManager.xcodeproj" \
  -scheme CodexAccountManager -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$derived_data" build
built_app="$derived_data/Build/Products/Release/CAM.app"
app="${CODEX_SWITCHER_APP_PATH:-$project_dir/dist/CAM.app}"
if [ "$built_app" != "$app" ]; then
  mkdir -p "$(dirname "$app")"
  ditto "$built_app" "$app"
  codesign --force --sign - "$app"
fi
echo "Built: $app"
