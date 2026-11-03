#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
derived_data="${CAM_DERIVED_DATA:-$project_dir/.build/xcode}"
xcodebuild -project "$project_dir/CodexAccountManager.xcodeproj" \
  -scheme CodexAccountManager -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$derived_data" build
built_app="$derived_data/Build/Products/Release/Codex Account Manager.app"
app="${CAM_APP_PATH:-$project_dir/dist/Codex Account Manager.app}"
if [ "$built_app" != "$app" ]; then
  case "$app" in
    *.app) ;;
    *) echo "应用输出路径必须以 .app 结尾: $app" >&2; exit 1 ;;
  esac
  mkdir -p "$app"
  rsync -a --delete "$built_app/" "$app/"
  codesign --force --sign - "$app"
fi
echo "Built: $app"
