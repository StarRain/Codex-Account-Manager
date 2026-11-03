#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
app="${CAM_APP_PATH:-$project_dir/dist/Codex Account Manager.app}"

if [ ! -d "$app" ] || [ ! -f "$app/Contents/Info.plist" ]; then
  echo "找不到应用，请先运行 sh scripts/build.sh: $app" >&2
  exit 1
fi
if ! command -v create-dmg >/dev/null 2>&1; then
  echo "请先安装 create-dmg: brew install create-dmg" >&2
  exit 1
fi

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
case "$version" in
  ''|*[!0-9.]*) echo "无效的应用版本号: $version" >&2; exit 1 ;;
esac
dmg="${CAM_DMG_PATH:-$project_dir/dist/Codex-Account-Manager-v${version}-macOS.dmg}"
case "$dmg" in
  *.dmg) ;;
  *) echo "安装包输出路径必须以 .dmg 结尾: $dmg" >&2; exit 1 ;;
esac
if [ -e "$dmg" ] || [ -L "$dmg" ]; then
  echo "安装包已存在，请选择其他输出路径: $dmg" >&2
  exit 1
fi

staging=$(mktemp -d "${TMPDIR:-/tmp}/cam-dmg.XXXXXX")
trap 'rm -rf "$staging"' EXIT
trap 'exit 1' HUP INT TERM
mkdir -p "$staging/contents" "$(dirname -- "$dmg")"
ditto "$app" "$staging/contents/Codex Account Manager.app"
swift "$project_dir/scripts/render-dmg-background.swift" "$staging/background.png"
create-dmg --volname "Codex Account Manager" \
  --volicon "$project_dir/CodexAccountManager/Resources/AppIcon.icns" \
  --background "$staging/background.png" --window-pos 200 120 --window-size 720 450 \
  --icon-size 112 --text-size 13 --icon "Codex Account Manager.app" 168 230 \
  --hide-extension "Codex Account Manager.app" --app-drop-link 552 230 \
  --format UDZO "$dmg" "$staging/contents"
echo "Built: $dmg"
