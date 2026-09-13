#!/bin/zsh
set -euo pipefail
readonly PROJECT_DIR="${0:A:h:h}"
readonly ICON_TOOL="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}/../Applications/Icon Composer.app/Contents/Executables/ictool"
readonly ICON_DOCUMENT="$PROJECT_DIR/App/AppIcon.icon"
readonly OUTPUT_DIR="$PROJECT_DIR/design/icon"

[[ -x "$ICON_TOOL" ]] || { print -u2 'Icon Composer付属のictoolが必要です。Xcode 26以降を指定してください。'; exit 1; }
mkdir -p "$OUTPUT_DIR"
for rendition in Default Dark TintedLight; do
  case "$rendition" in
    Default) name=default ;;
    Dark) name=dark ;;
    TintedLight) name=mono ;;
  esac
  "$ICON_TOOL" "$ICON_DOCUMENT" --export-image --output-file "$OUTPUT_DIR/preview-$name.png" \
    --platform macOS --rendition "$rendition" --width 512 --height 512 --scale 1
done
for size in 32 64 1024; do
  "$ICON_TOOL" "$ICON_DOCUMENT" --export-image --output-file "$OUTPUT_DIR/icon-$size.png" \
    --platform macOS --rendition Default --width "$size" --height "$size" --scale 1
done
print -- "アイコンを書き出しました: $OUTPUT_DIR"
