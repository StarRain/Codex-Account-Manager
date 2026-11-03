#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source="$project_dir/assets/cam-app-icon-trimmed.png"
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cam-icon.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT
iconset="$temp_dir/AppIcon.iconset"
mkdir -p "$iconset" "$project_dir/CodexAccountManager/Resources"
make_icon() {
  sips -z "$1" "$1" "$source" --out "$iconset/$2" >/dev/null
}
make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png
# Assemble the standard ICNS representations from the resized PNGs. Some
# versions of iconutil reject otherwise valid PNG iconsets when encoding.
python3 - "$iconset" "$temp_dir/AppIcon.icns" <<'PY'
import struct
import sys
from pathlib import Path

iconset = Path(sys.argv[1])
entries = [
    ("icp4", "icon_16x16.png"), ("ic11", "icon_16x16@2x.png"),
    ("icp5", "icon_32x32.png"), ("ic12", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"), ("ic13", "icon_128x128@2x.png"),
    ("ic08", "icon_256x256.png"), ("ic14", "icon_256x256@2x.png"),
    ("ic09", "icon_512x512.png"), ("ic10", "icon_512x512@2x.png"),
]
chunks = []
for kind, name in entries:
    png = (iconset / name).read_bytes()
    chunks.append(kind.encode("ascii") + struct.pack(">I", len(png) + 8) + png)
body = b"".join(chunks)
Path(sys.argv[2]).write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
PY
iconutil -c iconset "$temp_dir/AppIcon.icns" -o "$temp_dir/verified.iconset"
cp "$temp_dir/AppIcon.icns" "$project_dir/assets/cam-app-icon-trimmed.icns"
cp "$temp_dir/AppIcon.icns" "$project_dir/CodexAccountManager/Resources/AppIcon.icns"
