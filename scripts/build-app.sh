#!/bin/sh
# Builds build/FreeRetina.app (Apple Silicon only).
# Signs with $SIGN_IDENTITY, else the first "Apple Development" identity, else ad-hoc.
# A real identity matters: macOS ties the Screen Recording permission to the signature's
# designated requirement. Ad-hoc signatures pin it to the exact binary hash, so every
# rebuild silently loses the permission.
set -eu
cd "$(dirname "$0")/.."
swift build -c release --arch arm64
app=build/FreeRetina.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/arm64-apple-macosx/release/freeretina "$app/Contents/MacOS/FreeRetina"
cp Resources/Info.plist "$app/Contents/Info.plist"
identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)}"
if [ -z "$identity" ]; then
    echo "warning: no signing identity; ad-hoc signing (Screen Recording permission resets on every rebuild)" >&2
    identity=-
fi
codesign --force --sign "$identity" --identifier app.freeretina.FreeRetina "$app"
echo "built $app"
