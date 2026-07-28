#!/bin/bash
# 把 Resources/AppIcon.png（1024x1024）转成 macOS 的 Resources/AppIcon.icns。
# 依赖 sips 和 iconutil —— 两者都是 macOS 自带，无需额外安装。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/Resources/AppIcon.png"
ICONSET="$ROOT/build/AppIcon.iconset"
OUT="$ROOT/Resources/AppIcon.icns"

if [[ ! -f "$SRC" ]]; then
    echo "找不到 $SRC" >&2
    exit 1
fi

if ! command -v iconutil >/dev/null 2>&1; then
    echo "iconutil 不可用 —— 这个脚本只能在 macOS 上运行" >&2
    exit 1
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# iconutil 要求的固定文件名与尺寸组合，少一个都会报错
render() {
    local size="$1" name="$2"
    sips -z "$size" "$size" "$SRC" --out "$ICONSET/$name" >/dev/null
}

render 16 icon_16x16.png
render 32 icon_16x16@2x.png
render 32 icon_32x32.png
render 64 icon_32x32@2x.png
render 128 icon_128x128.png
render 256 icon_128x128@2x.png
render 256 icon_256x256.png
render 512 icon_256x256@2x.png
render 512 icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil --convert icns "$ICONSET" --output "$OUT"
rm -rf "$ICONSET"

echo "已生成 $OUT"
