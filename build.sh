#!/bin/bash
set -euo pipefail

cd -- "$(dirname -- "$0")"
out="$PWD/build/Kindle 投放.app"
mkdir -p "$out/Contents/MacOS"
cp Info.plist "$out/Contents/Info.plist"

flags=()
clt=/Library/Developer/CommandLineTools
maps="$clt/usr/include/swift"
if [[ "$(xcode-select -p)" == "$clt" && -f "$maps/bridging.modulemap" &&
      -f "$maps/module.modulemap" ]] && grep -q '^module SwiftBridging' "$maps/module.modulemap"; then
    # Older Command Line Tools upgrades can leave two declarations of SwiftBridging.
    # Hide the obsolete map for this build without changing the installed tools.
    overlay_dir="$(mktemp -d /tmp/kindle-cast-build.XXXXXX)"
    trap 'unlink "$overlay_dir/overlay.json"; unlink "$overlay_dir/empty.modulemap"; rmdir "$overlay_dir"' EXIT
    : > "$overlay_dir/empty.modulemap"
    cat > "$overlay_dir/overlay.json" <<EOF
{"version":0,"use-external-names":false,"roots":[{"type":"directory","name":"$maps","contents":[{"type":"file","name":"module.modulemap","external-contents":"$overlay_dir/empty.modulemap"}]}]}
EOF
    flags=(-vfsoverlay "$overlay_dir/overlay.json" -Xcc -ivfsoverlay -Xcc "$overlay_dir/overlay.json")
fi

swiftc "${flags[@]}" -O -target arm64-apple-macos14.0 Sources/*.swift -o "$out/Contents/MacOS/KindleCast"
codesign --force --sign - "$out"
printf '%s\n' "$out"
