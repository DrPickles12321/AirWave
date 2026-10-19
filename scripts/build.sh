#!/bin/bash
# Builds AirWave with swiftc directly (no Xcode or SwiftPM needed).
#   scripts/build.sh            build build/AirWave.app
#   scripts/build.sh selftest   build and run the offline sonar self-test
#   scripts/build.sh run        build the app and open it
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build
mkdir -p "$OUT"

# Some Command Line Tools installs ship two module maps that both define SwiftBridging, which
# breaks importing any Apple framework. Hide the duplicate from the compiler (system files untouched).
FLAGS=(-O -swift-version 5 -target arm64-apple-macos14.0)
DUP=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
if [[ -f "$DUP" && -f /Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap ]]; then
  : > "$OUT/empty.modulemap"
  cat > "$OUT/overlay.yaml" <<EOF
{ "version": 0, "case-sensitive": "false", "roots": [ { "name": "$(dirname "$DUP")", "type": "directory",
  "contents": [ { "name": "module.modulemap", "type": "file", "external-contents": "$PWD/$OUT/empty.modulemap" } ] } ] }
EOF
  FLAGS+=(-vfsoverlay "$OUT/overlay.yaml" -Xcc -ivfsoverlay -Xcc "$PWD/$OUT/overlay.yaml")
fi

echo "› SonarCore"
swiftc "${FLAGS[@]}" -parse-as-library -module-name SonarCore \
  -emit-module -emit-module-path "$OUT/SonarCore.swiftmodule" \
  -emit-library -static -o "$OUT/libSonarCore.a" Sources/SonarCore/*.swift

if [[ "${1:-}" == "selftest" ]]; then
  echo "› SonarSelfTest"
  swiftc "${FLAGS[@]}" -I "$OUT" -L "$OUT" -lSonarCore -o "$OUT/SonarSelfTest" Sources/SonarSelfTest/main.swift
  exec "$OUT/SonarSelfTest"
fi

echo "› AirWave.app"
APP="$OUT/AirWave.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc "${FLAGS[@]}" -parse-as-library -I "$OUT" -L "$OUT" -lSonarCore -o "$APP/Contents/MacOS/AirWave" Sources/AirWave/*.swift
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Ad-hoc signature so macOS remembers the microphone permission between launches.
codesign --force --sign - "$APP" >/dev/null
echo "✓ $APP"

if [[ "${1:-}" == "run" ]]; then
  open "$APP"
fi
